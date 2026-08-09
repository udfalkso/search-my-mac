import CryptoKit
import Foundation
import llama

struct SemanticModelDescriptor: Sendable {
    /// Bump when the text sent to the embedding model changes. Existing vectors
    /// then need a semantic-only rebuild; the lexical index and source files are
    /// unaffected.
    static let embeddingFormatVersion = 3

    static let qwen3 = SemanticModelDescriptor(
        id: "qwen3-embedding-0.6b-q8",
        displayName: "Qwen3 Embedding 0.6B",
        filename: "Qwen3-Embedding-0.6B-Q8_0.gguf",
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/main/Qwen3-Embedding-0.6B-Q8_0.gguf")!,
        expectedBytes: 639_150_592,
        sha256: "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439",
        dimensions: 1_024
    )

    let id: String
    let displayName: String
    let filename: String
    let downloadURL: URL
    let expectedBytes: Int64
    let sha256: String
    let dimensions: Int

    /// Preserve complete content for semantic retrieval while normalizing
    /// whitespace introduced by document extractors. Numeric values may be
    /// meaningful, particularly in financial and spreadsheet data.
    static func normalizedPassageForEmbedding(_ passage: String) -> String {
        passage
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Keep the title close to every passage. It often captures a user's intent
    /// more directly than the dense body of a structured form or scanned page.
    static func documentInput(filename: String, passage: String) -> String {
        let title = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPassage = normalizedPassageForEmbedding(passage)
        guard !title.isEmpty else { return normalizedPassage }
        return "Document title: \(title)\n\nDocument passage:\n\(normalizedPassage)"
    }
}

actor SemanticModelManager {
    let descriptor = SemanticModelDescriptor.qwen3
    private let directory: URL
    private let isReadOnly: Bool

    init(storageURL: URL, readOnly: Bool = false) throws {
        directory = storageURL.appendingPathComponent("Models", isDirectory: true)
        isReadOnly = readOnly
        if !readOnly {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    var modelURL: URL { directory.appendingPathComponent(descriptor.filename) }

    func installedModelURL(validateChecksum: Bool = false) throws -> URL? {
        let url = modelURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)) ?? -1
        guard size == descriptor.expectedBytes else { return nil }
        if validateChecksum, try Self.sha256(of: url) != descriptor.sha256 { return nil }
        return url
    }

    func download(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        guard !isReadOnly else { throw SearchMyMacError.semantic("The model store was opened read-only.") }
        if let existing = try installedModelURL(validateChecksum: true) { return existing }
        let bridge = ModelDownloadBridge(url: descriptor.downloadURL, progress: progress)
        let (temporaryDownload, response) = try await bridge.download()
        defer { try? FileManager.default.removeItem(at: temporaryDownload) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SearchMyMacError.semantic("The model server returned an invalid response.")
        }
        let downloadedSize = ((try? temporaryDownload.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)) ?? -1
        guard downloadedSize == descriptor.expectedBytes else {
            throw SearchMyMacError.semantic("The downloaded model has an unexpected size.")
        }
        guard try Self.sha256(of: temporaryDownload) == descriptor.sha256 else {
            throw SearchMyMacError.semantic("The downloaded model failed its SHA-256 integrity check.")
        }

        let staging = directory.appendingPathComponent(descriptor.filename + ".download")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.moveItem(at: temporaryDownload, to: staging)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        if FileManager.default.fileExists(atPath: modelURL.path) {
            _ = try FileManager.default.replaceItemAt(modelURL, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: modelURL)
        }
        return modelURL
    }

    func remove() throws {
        guard !isReadOnly else { throw SearchMyMacError.semantic("The model store was opened read-only.") }
        if FileManager.default.fileExists(atPath: modelURL.path) {
            try FileManager.default.removeItem(at: modelURL)
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class ModelDownloadBridge: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let url: URL
    private let progressHandler: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var completed = false

    init(url: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.url = url
        self.progressHandler = progress
    }

    func download() async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: url)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler(min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let response = downloadTask.response else {
            finish(.failure(SearchMyMacError.semantic("The model download returned no response.")))
            return
        }
        let retained = FileManager.default.temporaryDirectory
            .appendingPathComponent("searchmymac-model-\(UUID().uuidString).download")
        do {
            try FileManager.default.moveItem(at: location, to: retained)
            progressHandler(1)
            finish(.success((retained, response)))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error { finish(.failure(error)) }
    }

    private func cancel() {
        lock.lock()
        let task = task
        lock.unlock()
        task?.cancel()
    }

    private func finish(_ result: Result<(URL, URLResponse), Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = continuation
        self.continuation = nil
        let session = session
        self.session = nil
        task = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}

package final class QwenEmbeddingModel: @unchecked Sendable {
    private static let initializeBackend: Void = {
        llama_backend_init()
    }()

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private let inferenceLock = NSLock()
    let dimensions: Int
    private let maximumTokens: Int

    package init(
        url: URL,
        dimensions: Int = 1_024,
        maximumTokens: Int = 2_048,
        useGPU: Bool = true,
        suppressLogs: Bool = false
    ) throws {
        if suppressLogs { llama_log_set({ _, _, _ in }, nil) }
        _ = Self.initializeBackend
        var modelParameters = llama_model_default_params()
        modelParameters.n_gpu_layers = useGPU && llama_supports_gpu_offload() ? -1 : 0
        modelParameters.use_mmap = true
        let loadedModel: OpaquePointer? = if useGPU {
            url.path.withCString { llama_model_load_from_file($0, modelParameters) }
        } else {
            try Self.loadCPUModel(at: url, parameters: &modelParameters)
        }
        guard let loadedModel else {
            throw SearchMyMacError.semantic("Qwen3 could not be loaded from disk.")
        }
        model = loadedModel
        self.dimensions = min(dimensions, Int(llama_model_n_embd(loadedModel)))
        self.maximumTokens = maximumTokens

        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = UInt32(maximumTokens)
        contextParameters.n_batch = UInt32(maximumTokens)
        contextParameters.n_ubatch = UInt32(min(maximumTokens, 512))
        contextParameters.n_seq_max = 1
        contextParameters.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        contextParameters.n_threads_batch = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        contextParameters.embeddings = true
        contextParameters.pooling_type = LLAMA_POOLING_TYPE_LAST
        guard let loadedContext = llama_init_from_model(loadedModel, contextParameters) else {
            llama_model_free(loadedModel)
            model = nil
            throw SearchMyMacError.semantic("Qwen3 could not allocate an inference context.")
        }
        context = loadedContext
        llama_set_embeddings(loadedContext, true)
    }

    private static func loadCPUModel(
        at url: URL,
        parameters: inout llama_model_params
    ) throws -> OpaquePointer? {
        guard let cpu = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU) else {
            throw SearchMyMacError.semantic("llama.cpp did not expose a CPU inference device.")
        }
        var devices: [ggml_backend_dev_t?] = [cpu, nil]
        return devices.withUnsafeMutableBufferPointer { buffer in
            parameters.devices = buffer.baseAddress
            return url.path.withCString { llama_model_load_from_file($0, parameters) }
        }
    }

    deinit {
        shutdown()
    }

    package func shutdown() {
        inferenceLock.lock()
        defer { inferenceLock.unlock() }
        if let context {
            llama_synchronize(context)
            llama_free(context)
            self.context = nil
        }
        if let model {
            llama_model_free(model)
            self.model = nil
        }
    }

    package func embedDocument(_ text: String) throws -> [Float] {
        try embed(text)
    }

    package func embedQuery(_ query: String) throws -> [Float] {
        let instruction = "Instruct: Given a search query, retrieve relevant passages from files on this Mac that answer or relate to the query\nQuery: \(query)"
        return try embed(instruction)
    }

    private func embed(_ text: String) throws -> [Float] {
        inferenceLock.lock()
        defer { inferenceLock.unlock() }
        guard let model, let context else { throw SearchMyMacError.semantic("The model is not loaded.") }
        let vocab = llama_model_get_vocab(model)
        // This GGUF declares add_eos_token=true. Asking llama.cpp to add special
        // tokens supplies the single final token required for last-token pooling.
        var tokens = try tokenize(text, vocabulary: vocab)
        guard !tokens.isEmpty else { throw SearchMyMacError.semantic("The tokenizer produced no input.") }
        if tokens.count > maximumTokens {
            let finalToken = tokens.last!
            tokens = Array(tokens.prefix(maximumTokens - 1)) + [finalToken]
        }

        llama_memory_clear(llama_get_memory(context), true)
        let decodeResult = tokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
        }
        guard decodeResult == 0 else {
            throw SearchMyMacError.semantic("Qwen3 inference failed with code \(decodeResult).")
        }
        guard let output = llama_get_embeddings_seq(context, 0) else {
            throw SearchMyMacError.semantic("Qwen3 did not return a pooled embedding.")
        }
        var vector = Array(UnsafeBufferPointer(start: output, count: dimensions))
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else { throw SearchMyMacError.semantic("Qwen3 returned an invalid embedding.") }
        for index in vector.indices { vector[index] /= norm }
        return vector
    }

    private func tokenize(_ text: String, vocabulary: OpaquePointer?) throws -> [llama_token] {
        guard let vocabulary else { throw SearchMyMacError.semantic("The model has no tokenizer vocabulary.") }
        let bytes = Array(text.utf8)
        let required = bytes.withUnsafeBytes { raw -> Int32 in
            let pointer = raw.bindMemory(to: CChar.self).baseAddress
            return llama_tokenize(vocabulary, pointer, Int32(bytes.count), nil, 0, true, true)
        }
        let count = required < 0 ? Int(-required) : Int(required)
        guard count > 0 else { return [] }
        var tokens = Array(repeating: llama_token(0), count: count)
        let written = bytes.withUnsafeBytes { raw -> Int32 in
            let pointer = raw.bindMemory(to: CChar.self).baseAddress
            return tokens.withUnsafeMutableBufferPointer { buffer in
                llama_tokenize(vocabulary, pointer, Int32(bytes.count), buffer.baseAddress, Int32(buffer.count), true, true)
            }
        }
        guard written >= 0 else { throw SearchMyMacError.semantic("The text could not be tokenized.") }
        if Int(written) < tokens.count { tokens.removeLast(tokens.count - Int(written)) }
        return tokens
    }
}

/// Experimental local generator used by the semantic benchmark to turn noisy
/// extracted document text into a compact retrieval-oriented document card.
/// It is deliberately not wired into production indexing until the focused
/// quality and cost measurements justify that architecture.
package final class QwenDocumentCardGenerator: @unchecked Sendable {
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private let lock = NSLock()
    private let maximumTokens: Int

    package init(
        url: URL,
        maximumTokens: Int = 4_096,
        useGPU: Bool = true,
        suppressLogs: Bool = false
    ) throws {
        if suppressLogs { llama_log_set({ _, _, _ in }, nil) }
        llama_backend_init()
        var modelParameters = llama_model_default_params()
        modelParameters.n_gpu_layers = useGPU && llama_supports_gpu_offload() ? -1 : 0
        modelParameters.use_mmap = true
        let loadedModel: OpaquePointer? = if useGPU {
            url.path.withCString { llama_model_load_from_file($0, modelParameters) }
        } else {
            try Self.loadCPUModel(at: url, parameters: &modelParameters)
        }
        guard let loadedModel else {
            throw SearchMyMacError.semantic("Qwen3 document-card generator could not be loaded from disk.")
        }
        model = loadedModel
        self.maximumTokens = maximumTokens

        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = UInt32(maximumTokens)
        // A full-context logical batch makes Metal reserve substantially more
        // temporary memory than this one-sequence workload needs.
        contextParameters.n_batch = UInt32(min(maximumTokens, 1_024))
        contextParameters.n_ubatch = UInt32(min(maximumTokens, 512))
        contextParameters.n_seq_max = 1
        contextParameters.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        contextParameters.n_threads_batch = contextParameters.n_threads
        contextParameters.embeddings = false
        contextParameters.pooling_type = LLAMA_POOLING_TYPE_NONE
        guard let loadedContext = llama_init_from_model(loadedModel, contextParameters) else {
            llama_model_free(loadedModel)
            model = nil
            throw SearchMyMacError.semantic("Qwen3 document-card generator could not allocate an inference context.")
        }
        context = loadedContext
    }

    private static func loadCPUModel(
        at url: URL,
        parameters: inout llama_model_params
    ) throws -> OpaquePointer? {
        guard let cpu = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU) else {
            throw SearchMyMacError.semantic("llama.cpp did not expose a CPU inference device.")
        }
        var devices: [ggml_backend_dev_t?] = [cpu, nil]
        return devices.withUnsafeMutableBufferPointer { buffer in
            parameters.devices = buffer.baseAddress
            return url.path.withCString { llama_model_load_from_file($0, parameters) }
        }
    }

    deinit { shutdown() }

    package func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        if let context {
            llama_synchronize(context)
            llama_free(context)
            self.context = nil
        }
        if let model {
            llama_model_free(model)
            self.model = nil
        }
    }

    package func generate(filename: String, path: String, extractedText: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let model, let context else {
            throw SearchMyMacError.semantic("The document-card generator is not loaded.")
        }
        let system = """
        You create compact semantic search cards for local files. Describe the document's purpose and broad topics in plain everyday language. Translate formal document language into the words a person would naturally use to search for the file. Infer the life event, task, or business purpose supported by the evidence. Include several short likely search phrases and synonyms (for example, "buying a home" for a residential purchase or "job search" for employment applications). Preserve meaningful domain terms. Do not invent facts. Ignore repetitive table values and identifiers unless they define the document's purpose. Return exactly three lines labeled Summary, Topics, and Likely searches.
        """
        let user = """
        Filename: \(filename)
        Folder: \(path)
        Extracted text:
        \(extractedText)
        /no_think
        """
        let prompt = "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
        let vocabulary = llama_model_get_vocab(model)
        var promptTokens = try tokenize(prompt, vocabulary: vocabulary)
        // Reserve room for a concise generated card.
        let maximumPromptTokens = maximumTokens - 256
        if promptTokens.count > maximumPromptTokens {
            promptTokens = Array(promptTokens.prefix(maximumPromptTokens))
        }
        guard !promptTokens.isEmpty else {
            throw SearchMyMacError.semantic("The document-card prompt produced no tokens.")
        }

        llama_memory_clear(llama_get_memory(context), true)
        let promptResult = promptTokens.withUnsafeMutableBufferPointer {
            llama_decode(context, llama_batch_get_one($0.baseAddress, Int32($0.count)))
        }
        guard promptResult == 0 else {
            throw SearchMyMacError.semantic("Qwen3 document-card prompt inference failed with code \(promptResult).")
        }
        guard let sampler = llama_sampler_init_greedy() else {
            throw SearchMyMacError.semantic("Qwen3 could not create a document-card sampler.")
        }
        defer { llama_sampler_free(sampler) }

        var output = Data()
        for _ in 0..<140 {
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocabulary, token) { break }
            output.append(try piece(for: token, vocabulary: vocabulary))
            var next = token
            let decodeResult = llama_decode(context, llama_batch_get_one(&next, 1))
            guard decodeResult == 0 else {
                throw SearchMyMacError.semantic("Qwen3 document-card generation failed with code \(decodeResult).")
            }
        }
        guard var result = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty else {
            throw SearchMyMacError.semantic("Qwen3 produced an empty document card.")
        }
        if let thinkStart = result.range(of: "<think>"),
           let thinkEnd = result.range(of: "</think>", range: thinkStart.upperBound..<result.endIndex) {
            result.removeSubrange(thinkStart.lowerBound..<thinkEnd.upperBound)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private func tokenize(_ text: String, vocabulary: OpaquePointer?) throws -> [llama_token] {
        guard let vocabulary else { throw SearchMyMacError.semantic("The generator has no tokenizer vocabulary.") }
        let bytes = Array(text.utf8)
        let required = bytes.withUnsafeBytes {
            llama_tokenize(vocabulary, $0.bindMemory(to: CChar.self).baseAddress, Int32(bytes.count), nil, 0, false, true)
        }
        let count = Int(abs(required))
        guard count > 0 else { return [] }
        var tokens = Array(repeating: llama_token(0), count: count)
        let written = bytes.withUnsafeBytes { raw in
            tokens.withUnsafeMutableBufferPointer {
                llama_tokenize(vocabulary, raw.bindMemory(to: CChar.self).baseAddress, Int32(bytes.count), $0.baseAddress, Int32($0.count), false, true)
            }
        }
        guard written >= 0 else { throw SearchMyMacError.semantic("The generator prompt could not be tokenized.") }
        if Int(written) < tokens.count { tokens.removeLast(tokens.count - Int(written)) }
        return tokens
    }

    private func piece(for token: llama_token, vocabulary: OpaquePointer?) throws -> Data {
        guard let vocabulary else { throw SearchMyMacError.semantic("The generator has no tokenizer vocabulary.") }
        var buffer = Array(repeating: CChar(0), count: 256)
        var written = llama_token_to_piece(vocabulary, token, &buffer, Int32(buffer.count), 0, false)
        if written < 0 {
            buffer = Array(repeating: CChar(0), count: Int(-written))
            written = llama_token_to_piece(vocabulary, token, &buffer, Int32(buffer.count), 0, false)
        }
        guard written >= 0 else { throw SearchMyMacError.semantic("A generated token could not be decoded.") }
        return buffer.withUnsafeBytes { Data($0.prefix(Int(written))) }
    }
}

/// Cross-encoder scorer for the top semantic candidates. Unlike an embedding,
/// it reads the query and document together and returns a calibrated local
/// yes/no relevance probability.
final class QwenRerankerModel: @unchecked Sendable {
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private let lock = NSLock()
    private let maximumTokens = 4_096

    init(url: URL, useGPU: Bool = true, suppressLogs: Bool = false) throws {
        if suppressLogs { llama_log_set({ _, _, _ in }, nil) }
        llama_backend_init()
        var parameters = llama_model_default_params()
        parameters.n_gpu_layers = useGPU && llama_supports_gpu_offload() ? -1 : 0
        parameters.use_mmap = true
        guard let loaded = url.path.withCString({ llama_model_load_from_file($0, parameters) }) else {
            throw SearchMyMacError.semantic("Qwen reranker could not be loaded from disk.")
        }
        model = loaded
        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = UInt32(maximumTokens)
        contextParameters.n_batch = UInt32(maximumTokens)
        contextParameters.n_ubatch = UInt32(min(maximumTokens, 512))
        contextParameters.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        contextParameters.n_threads_batch = contextParameters.n_threads
        contextParameters.embeddings = false
        contextParameters.pooling_type = LLAMA_POOLING_TYPE_NONE
        guard let loadedContext = llama_init_from_model(loaded, contextParameters) else {
            llama_model_free(loaded)
            model = nil
            throw SearchMyMacError.semantic("Qwen reranker could not allocate an inference context.")
        }
        context = loadedContext
    }

    deinit { shutdown() }

    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        if let context { llama_synchronize(context); llama_free(context); self.context = nil }
        if let model { llama_model_free(model); self.model = nil }
    }

    func score(query: String, document: String) throws -> Float {
        lock.lock(); defer { lock.unlock() }
        guard let model, let context else { throw SearchMyMacError.semantic("The Qwen reranker is not loaded.") }
        let instruction = "Given a local-file search query, retrieve documents that directly answer or are meaningfully related to the query."
        let prompt = "<|im_start|>system\nJudge whether the Document meets the requirements based on the Query and the Instruct provided. Note that the answer can only be \"yes\" or \"no\".<|im_end|>\n<|im_start|>user\n<Instruct>: \(instruction)\n<Query>: \(query)\n<Document>: \(document)\n<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        let vocab = llama_model_get_vocab(model)
        var tokens = try tokenize(prompt, vocabulary: vocab, addSpecial: false)
        if tokens.count > maximumTokens { tokens = Array(tokens.prefix(maximumTokens)) }
        let yes = try requiredSingleToken("yes", vocabulary: vocab)
        let no = try requiredSingleToken("no", vocabulary: vocab)
        llama_memory_clear(llama_get_memory(context), true)
        let result = tokens.withUnsafeMutableBufferPointer { llama_decode(context, llama_batch_get_one($0.baseAddress, Int32($0.count))) }
        guard result == 0, let logits = llama_get_logits_ith(context, -1) else {
            throw SearchMyMacError.semantic("Qwen reranker inference failed.")
        }
        let yesLogit = logits[Int(yes)], noLogit = logits[Int(no)]
        let maximum = max(yesLogit, noLogit)
        let yesExp = exp(yesLogit - maximum), noExp = exp(noLogit - maximum)
        return yesExp / (yesExp + noExp)
    }

    private func requiredSingleToken(_ text: String, vocabulary: OpaquePointer?) throws -> llama_token {
        let tokens = try tokenize(text, vocabulary: vocabulary, addSpecial: false)
        guard let token = tokens.first else { throw SearchMyMacError.semantic("The reranker tokenizer could not encode \(text).") }
        return token
    }

    private func tokenize(_ text: String, vocabulary: OpaquePointer?, addSpecial: Bool) throws -> [llama_token] {
        guard let vocabulary else { throw SearchMyMacError.semantic("The reranker has no tokenizer vocabulary.") }
        let bytes = Array(text.utf8)
        let required = bytes.withUnsafeBytes { raw in llama_tokenize(vocabulary, raw.bindMemory(to: CChar.self).baseAddress, Int32(bytes.count), nil, 0, addSpecial, true) }
        let count = Int(abs(required)); guard count > 0 else { return [] }
        var tokens = Array(repeating: llama_token(0), count: count)
        let written = bytes.withUnsafeBytes { raw in tokens.withUnsafeMutableBufferPointer { llama_tokenize(vocabulary, raw.bindMemory(to: CChar.self).baseAddress, Int32(bytes.count), $0.baseAddress, Int32($0.count), addSpecial, true) } }
        guard written >= 0 else { throw SearchMyMacError.semantic("The reranker prompt could not be tokenized.") }
        return Array(tokens.prefix(Int(written)))
    }
}

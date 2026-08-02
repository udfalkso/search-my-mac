import CryptoKit
import Foundation
import llama

struct SemanticModelDescriptor: Sendable {
    static let qwen3 = SemanticModelDescriptor(
        id: "qwen3-embedding-0.6b-q8",
        displayName: "Qwen3 Embedding 0.6B (Q8)",
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
}

actor SemanticModelManager {
    let descriptor = SemanticModelDescriptor.qwen3
    private let directory: URL

    init(storageURL: URL) throws {
        directory = storageURL.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
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

final class QwenEmbeddingModel: @unchecked Sendable {
    private static let initializeBackend: Void = {
        llama_backend_init()
    }()

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private let inferenceLock = NSLock()
    let dimensions: Int
    private let maximumTokens: Int

    init(url: URL, dimensions: Int = 1_024, maximumTokens: Int = 2_048) throws {
        _ = Self.initializeBackend
        var modelParameters = llama_model_default_params()
        modelParameters.n_gpu_layers = llama_supports_gpu_offload() ? -1 : 0
        modelParameters.use_mmap = true
        guard let loadedModel = url.path.withCString({ llama_model_load_from_file($0, modelParameters) }) else {
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

    deinit {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
    }

    func embedDocument(_ text: String) throws -> [Float] {
        try embed(text)
    }

    func embedQuery(_ query: String) throws -> [Float] {
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

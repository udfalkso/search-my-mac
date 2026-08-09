import Darwin
import Foundation

struct TantivyPassageInput: Codable, Sendable {
    let passageID: UInt64
    let body: String
}

struct TantivyDocumentInput: Codable, Sendable {
    let sourceID: String
    let generation: Int64
    let filename: String
    let title: String
    let path: String
    let modifiedAt: Int64
    let availability: String
    let rootID: String
    let `extension`: String
    let passages: [TantivyPassageInput]
}

struct TantivyPassageHit: Codable, Sendable {
    let passageID: UInt64
    let body: String
    let score: Float
    enum CodingKeys: String, CodingKey { case passageID = "passage_id", body, score }
}

struct TantivySearchHit: Codable, Sendable {
    let sourceID: String
    let filename: String
    let path: String
    let availability: String
    let modifiedAt: Int64
    let score: Float
    let passages: [TantivyPassageHit]
    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id", filename, path, availability
        case modifiedAt = "modified_at"
        case score, passages
    }
}

struct TantivySearchOutput: Codable, Sendable {
    let hits: [TantivySearchHit]
}

private struct TantivySearchInput: Codable {
    let query: String
    let limit: Int
    let offset: Int
    let rootIDs: [String]
    let pathPrefixes: [String]
    let extensions: [String]
    let modifiedAfter: Int64?
    let modifiedBefore: Int64?
}

/// Dynamically loads the bundled Rust engine so Swift tests and development
/// builds can still run when the derived Tantivy library has not been built.
final class TantivyEngineBridge: @unchecked Sendable {
    private typealias Open = @convention(c) (UnsafePointer<CChar>) -> OpaquePointer?
    private typealias Release = @convention(c) (OpaquePointer?) -> Void
    private typealias JSONCall = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    private typealias EngineCall = @convention(c) (OpaquePointer?) -> UnsafeMutablePointer<CChar>?
    private typealias CommitGeneration = @convention(c) (OpaquePointer?, Int64) -> UnsafeMutablePointer<CChar>?
    private typealias StringFree = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    private let library: UnsafeMutableRawPointer
    private let engine: OpaquePointer
    private let releaseFunction: Release
    private let upsertFunction: JSONCall
    private let deleteFunction: JSONCall
    private let searchFunction: JSONCall
    private let resetFunction: EngineCall
    private let generationFunction: EngineCall
    private let commitFunction: CommitGeneration
    private let stringFreeFunction: StringFree
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init?(indexURL: URL) {
        guard let libraryURL = Self.libraryURLs().first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let library = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        func symbol<T>(_ name: String, _: T.Type) -> T? {
            guard let pointer = dlsym(library, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let open = symbol("smm_engine_open", Open.self),
              let release = symbol("smm_engine_release", Release.self),
              let upsert = symbol("smm_engine_upsert", JSONCall.self),
              let delete = symbol("smm_engine_delete", JSONCall.self),
              let search = symbol("smm_engine_search", JSONCall.self),
              let reset = symbol("smm_engine_reset", EngineCall.self),
              let generation = symbol("smm_engine_committed_generation", EngineCall.self),
              let commit = symbol("smm_engine_commit_generation", CommitGeneration.self),
              let stringFree = symbol("smm_string_free", StringFree.self) else {
            dlclose(library)
            return nil
        }
        guard let engine = indexURL.path.withCString({ open($0) }) else {
            dlclose(library)
            return nil
        }
        self.library = library
        self.engine = engine
        releaseFunction = release
        upsertFunction = upsert
        deleteFunction = delete
        searchFunction = search
        resetFunction = reset
        generationFunction = generation
        commitFunction = commit
        stringFreeFunction = stringFree
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        decoder = JSONDecoder()
    }

    deinit {
        releaseFunction(engine)
        dlclose(library)
    }

    func upsert(_ document: TantivyDocumentInput) throws {
        try callJSON(upsertFunction, value: document)
    }

    func delete(sourceID: String) throws {
        try sourceID.withCString { pointer in try check(deleteFunction(engine, pointer)) }
    }

    func reset() throws { try check(resetFunction(engine)) }

    func committedGeneration() throws -> Int64 {
        try decode(generationFunction(engine), as: Int64.self)
    }

    func commit(generation: Int64) throws {
        _ = try decode(commitFunction(engine, generation), as: UInt64.self)
    }

    func search(_ request: SearchRequest, offset: Int) throws -> TantivySearchOutput {
        let input = TantivySearchInput(
            query: request.query, limit: request.limit, offset: offset,
            rootIDs: request.filters.rootIDs.sorted(), pathPrefixes: request.filters.pathPrefixes.sorted(),
            extensions: request.filters.extensions.sorted(),
            modifiedAfter: request.filters.modifiedAfter.map { Int64($0.timeIntervalSince1970) },
            modifiedBefore: request.filters.modifiedBefore.map { Int64($0.timeIntervalSince1970) }
        )
        return try callJSON(searchFunction, value: input, response: TantivySearchOutput.self)
    }

    private func callJSON<T: Encodable>(_ function: JSONCall, value: T) throws {
        let data = try encoder.encode(value)
        guard let json = String(data: data, encoding: .utf8) else { throw SearchMyMacError.database("Unable to encode Tantivy request") }
        try json.withCString { pointer in try check(function(engine, pointer)) }
    }

    private func callJSON<T: Encodable, U: Decodable>(_ function: JSONCall, value: T, response: U.Type) throws -> U {
        let data = try encoder.encode(value)
        guard let json = String(data: data, encoding: .utf8) else { throw SearchMyMacError.database("Unable to encode Tantivy request") }
        return try json.withCString { pointer in try decode(function(engine, pointer), as: response) }
    }

    private func check(_ pointer: UnsafeMutablePointer<CChar>?) throws {
        let object = try responseObject(pointer)
        guard object["ok"] as? Bool == true else {
            throw SearchMyMacError.database(object["error"] as? String ?? "Tantivy operation failed")
        }
    }

    private func decode<T: Decodable>(_ pointer: UnsafeMutablePointer<CChar>?, as type: T.Type) throws -> T {
        let data = try responseData(pointer)
        let envelope = try decoder.decode(Envelope<T>.self, from: data)
        guard envelope.ok, let value = envelope.value else {
            throw SearchMyMacError.database(envelope.error ?? "Tantivy operation failed")
        }
        return value
    }

    private func responseObject(_ pointer: UnsafeMutablePointer<CChar>?) throws -> [String: Any] {
        let data = try responseData(pointer)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SearchMyMacError.database("Invalid Tantivy response")
        }
        return object
    }

    private func responseData(_ pointer: UnsafeMutablePointer<CChar>?) throws -> Data {
        guard let pointer else { throw SearchMyMacError.database("Tantivy returned no response") }
        defer { stringFreeFunction(pointer) }
        return Data(String(cString: pointer).utf8)
    }

    private struct Envelope<T: Decodable>: Decodable {
        let ok: Bool
        let value: T?
        let error: String?
    }

    private static func libraryURLs() -> [URL] {
        var urls: [URL] = []
        if let configured = ProcessInfo.processInfo.environment["SMM_TANTIVY_LIBRARY_PATH"] {
            urls.append(URL(fileURLWithPath: configured))
        }
        if let frameworks = Bundle.main.privateFrameworksURL {
            urls.append(frameworks.appendingPathComponent("libsearchmymac_engine.dylib"))
        }
        if let executable = CommandLine.arguments.first {
            let executableDirectory = URL(fileURLWithPath: executable).standardizedFileURL.deletingLastPathComponent()
            urls.append(
                executableDirectory
                    .appendingPathComponent("../Frameworks/libsearchmymac_engine.dylib")
                    .standardizedFileURL
            )
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        urls.append(root.appendingPathComponent("rust-engine/target/debug/libsearchmymac_engine.dylib"))
        urls.append(root.appendingPathComponent("rust-engine/target/release/libsearchmymac_engine.dylib"))
        return urls
    }
}

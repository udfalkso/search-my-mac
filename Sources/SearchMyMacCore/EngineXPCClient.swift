import Foundation

public enum EngineXPCError: LocalizedError, Sendable {
    case missingSigningRequirement
    case unavailable
    case payloadTooLarge
    case malformedResponse
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .missingSigningRequirement: "The engine signing requirement is missing."
        case .unavailable: "The private search engine service is unavailable."
        case .payloadTooLarge: "The engine request or response exceeded its size limit."
        case .malformedResponse: "The engine returned a malformed response."
        case .timedOut: "The engine request timed out."
        }
    }
}

/// Authenticated client for the bundled engine service. The app currently keeps
/// filesystem discovery in-process; only derived index operations cross XPC.
public final class EngineXPCClient: @unchecked Sendable {
    private let connection: NSXPCConnection

    public init(
        serviceName: String = "com.searchmymac.app.engine",
        signingRequirement: String? = Bundle.main.object(forInfoDictionaryKey: "SMMEngineSigningRequirement") as? String
    ) throws {
        guard let signingRequirement, !signingRequirement.isEmpty else {
            throw EngineXPCError.missingSigningRequirement
        }
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = XPCSecurity.engineInterface()
        connection.setCodeSigningRequirement(signingRequirement)
        connection.resume()
        self.connection = connection
    }

    deinit { connection.invalidate() }

    public func search(_ request: SearchRequest, timeout: Duration = .seconds(10)) async throws -> SearchResponse {
        let requestData = try XPCCoding.encoder().encode(request)
        guard requestData.count <= XPCSecurity.maximumPayloadBytes else { throw EngineXPCError.payloadTooLarge }
        let responseData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let gate = XPCReplyGate(continuation)
            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: timeout)
                    gate.fail(EngineXPCError.timedOut)
                } catch { }
            }
            guard let proxy = self.connection.remoteObjectProxyWithErrorHandler({ error in
                timeoutTask.cancel()
                gate.fail(error)
            }) as? SearchMyMacEngineXPCProtocol else {
                timeoutTask.cancel()
                gate.fail(EngineXPCError.unavailable)
                return
            }
            proxy.search(request: requestData) { data, error in
                timeoutTask.cancel()
                if let error { gate.fail(error); return }
                guard let data else { gate.fail(EngineXPCError.malformedResponse); return }
                gate.succeed(data)
            }
        }
        guard responseData.count <= XPCSecurity.maximumPayloadBytes else { throw EngineXPCError.payloadTooLarge }
        return try XPCCoding.decoder().decode(SearchResponse.self, from: responseData)
    }
}

private final class XPCReplyGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: Value) {
        take()?.resume(returning: value)
    }

    func fail(_ error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let value = continuation
        continuation = nil
        return value
    }
}

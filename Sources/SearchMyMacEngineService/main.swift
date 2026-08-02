import Foundation
import SearchMyMacCore

private final class EngineService: NSObject, SearchMyMacEngineXPCProtocol, @unchecked Sendable {
    private let engine: LocalSearchEngine?
    private let startupError: NSError?

    override init() {
        do {
            engine = try LocalSearchEngine()
            startupError = nil
        } catch {
            engine = nil
            startupError = error as NSError
        }
        super.init()
    }

    func search(request: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        guard request.count <= XPCSecurity.maximumPayloadBytes else {
            reply(nil, NSError(domain: "SearchMyMacXPC", code: 413, userInfo: [NSLocalizedDescriptionKey: "Request exceeds the XPC payload limit"]))
            return
        }
        guard let engine else { reply(nil, startupError); return }
        Task {
            do {
                let decoded = try XPCCoding.decoder().decode(SearchRequest.self, from: request)
                let response = try await engine.search(decoded)
                reply(try XPCCoding.encoder().encode(response), nil)
            } catch { reply(nil, error as NSError) }
        }
    }

    func progress(withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        guard let engine else { reply(nil, startupError); return }
        Task { reply(try? XPCCoding.encoder().encode(await engine.progress()), nil) }
    }

    func health(withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        guard let engine else { reply(nil, startupError); return }
        Task {
            do { reply(try XPCCoding.encoder().encode(await engine.health()), nil) }
            catch { reply(nil, error as NSError) }
        }
    }

    func pause(reason: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        guard let engine else { reply(startupError); return }
        Task { await engine.pause(reason: reason); reply(nil) }
    }

    func resume(withReply reply: @escaping @Sendable (NSError?) -> Void) {
        guard let engine else { reply(startupError); return }
        Task { await engine.resume(); reply(nil) }
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = EngineService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement = Bundle.main.object(forInfoDictionaryKey: "SMMAuthorizedClientRequirement") as? String,
              !requirement.isEmpty else { return false }
        connection.exportedInterface = XPCSecurity.engineInterface()
        connection.exportedObject = service
        connection.setCodeSigningRequirement(requirement)
        connection.resume()
        return true
    }
}

private let delegate = ListenerDelegate()
private let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
RunLoop.current.run()

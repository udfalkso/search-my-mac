import Foundation

@objc public protocol SearchMyMacEngineXPCProtocol {
    func search(request: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func progress(withReply reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func health(withReply reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func pause(reason: String?, withReply reply: @escaping @Sendable (NSError?) -> Void)
    func resume(withReply reply: @escaping @Sendable (NSError?) -> Void)
}

public enum XPCCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum XPCSecurity {
    public static let maximumPayloadBytes = 1_048_576

    public static func engineInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: SearchMyMacEngineXPCProtocol.self)
        let dataClasses = NSSet(array: [NSData.self]) as! Set<AnyHashable>
        let errorClasses = NSSet(array: [NSError.self]) as! Set<AnyHashable>
        interface.setClasses(
            dataClasses,
            for: #selector(SearchMyMacEngineXPCProtocol.search(request:withReply:)),
            argumentIndex: 0,
            ofReply: false
        )
        interface.setClasses(
            dataClasses,
            for: #selector(SearchMyMacEngineXPCProtocol.search(request:withReply:)),
            argumentIndex: 0,
            ofReply: true
        )
        interface.setClasses(
            errorClasses,
            for: #selector(SearchMyMacEngineXPCProtocol.search(request:withReply:)),
            argumentIndex: 1,
            ofReply: true
        )
        return interface
    }
}

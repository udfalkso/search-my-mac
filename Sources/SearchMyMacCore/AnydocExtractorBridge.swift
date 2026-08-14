import Darwin
import Foundation

struct StructuredPDFPage: Decodable, Sendable, Equatable {
    let pageIndex: Int
    let text: String
    let needsOCR: Bool

    private enum CodingKeys: String, CodingKey {
        case pageIndex = "page_index"
        case text
        case needsOCR = "needs_ocr"
    }
}

protocol LocalDocumentParsing: Sendable {
    func extractDocument(data: Data, fileExtension: String) throws -> String
    func extractPDF(data: Data) throws -> [StructuredPDFPage]
}

struct LocalDocumentParserError: Error, LocalizedError, Sendable, Equatable {
    enum Code: String, Sendable {
        case unsupported
        case malformed
        case encrypted
        case resourceLimit
        case missingPart
        case io
        case invalidInput
        case panic
        case conversion
        case serialization
        case unavailable
    }

    let code: Code
    let message: String

    var errorDescription: String? { message }
}

/// Dynamically loads the bytes-only Rust document parser. Keeping the parser
/// behind this narrow interface lets the future extractor XPC service reuse it
/// without granting the Rust library filesystem access.
final class AnydocExtractorBridge: LocalDocumentParsing, @unchecked Sendable {
    private typealias DocumentExtract = @convention(c) (
        UnsafePointer<UInt8>?, Int, UnsafePointer<CChar>
    ) -> UnsafeMutablePointer<CChar>?
    private typealias PDFExtract = @convention(c) (
        UnsafePointer<UInt8>?, Int
    ) -> UnsafeMutablePointer<CChar>?
    private typealias StringFree = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    private let library: UnsafeMutableRawPointer
    private let documentExtract: DocumentExtract
    private let pdfExtractFunction: PDFExtract
    private let stringFree: StringFree
    private let decoder = JSONDecoder()

    init?() {
        _ = Self.configurePDFInspectorBCMaps
        guard let libraryURL = Self.libraryURLs().first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }), let library = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            return nil
        }
        func symbol<T>(_ name: String, _: T.Type) -> T? {
            guard let pointer = dlsym(library, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let documentExtract = symbol("smm_anydoc_extract", DocumentExtract.self),
              let pdfExtractFunction = symbol("smm_pdf_extract", PDFExtract.self),
              let stringFree = symbol("smm_extractor_string_free", StringFree.self) else {
            dlclose(library)
            return nil
        }
        self.library = library
        self.documentExtract = documentExtract
        self.pdfExtractFunction = pdfExtractFunction
        self.stringFree = stringFree
    }

    deinit {
        dlclose(library)
    }

    func extractDocument(data: Data, fileExtension: String) throws -> String {
        try fileExtension.withCString { extensionPointer in
            try data.withUnsafeBytes { buffer in
                let bytes = buffer.bindMemory(to: UInt8.self).baseAddress
                let response = documentExtract(bytes, buffer.count, extensionPointer)
                return try decode(response, as: DocumentOutput.self).text
            }
        }
    }

    func extractPDF(data: Data) throws -> [StructuredPDFPage] {
        try data.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self).baseAddress
            let response = pdfExtractFunction(bytes, buffer.count)
            return try decode(response, as: PDFOutput.self).pages
        }
    }

    private func decode<T: Decodable>(
        _ pointer: UnsafeMutablePointer<CChar>?,
        as type: T.Type
    ) throws -> T {
        guard let pointer else {
            throw LocalDocumentParserError(code: .unavailable, message: "Local document parser returned no response")
        }
        defer { stringFree(pointer) }
        let data = Data(String(cString: pointer).utf8)
        let envelope: Envelope<T>
        do {
            envelope = try decoder.decode(Envelope<T>.self, from: data)
        } catch {
            throw LocalDocumentParserError(code: .serialization, message: "Local document parser returned an invalid response")
        }
        if envelope.ok, let value = envelope.value {
            return value
        }
        throw LocalDocumentParserError(
            code: LocalDocumentParserError.Code(rawValue: envelope.errorCode ?? "") ?? .conversion,
            message: envelope.error ?? "Local document parsing failed"
        )
    }

    private struct DocumentOutput: Decodable {
        let text: String
    }

    private struct PDFOutput: Decodable {
        let pages: [StructuredPDFPage]
    }

    private struct Envelope<T: Decodable>: Decodable {
        let ok: Bool
        let value: T?
        let errorCode: String?
        let error: String?

        private enum CodingKeys: String, CodingKey {
            case ok, value, error
            case errorCode = "error_code"
        }
    }

    private static func libraryURLs() -> [URL] {
        var urls: [URL] = []
        if let configured = ProcessInfo.processInfo.environment["SMM_EXTRACTOR_LIBRARY_PATH"] {
            urls.append(URL(fileURLWithPath: configured))
        }
        if let frameworks = Bundle.main.privateFrameworksURL {
            urls.append(frameworks.appendingPathComponent("libsearchmymac_extractor.dylib"))
        }
        if let executable = CommandLine.arguments.first {
            let executableDirectory = URL(fileURLWithPath: executable)
                .standardizedFileURL.deletingLastPathComponent()
            urls.append(
                executableDirectory
                    .appendingPathComponent("../Frameworks/libsearchmymac_extractor.dylib")
                    .standardizedFileURL
            )
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        urls.append(root.appendingPathComponent("rust-extractor/target/debug/libsearchmymac_extractor.dylib"))
        urls.append(root.appendingPathComponent("rust-extractor/target/release/libsearchmymac_extractor.dylib"))
        return urls
    }

    private static let configurePDFInspectorBCMaps: Void = {
        guard getenv("PDF_INSPECTOR_BCMAPS_DIR") == nil else { return }
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("PDFInspectorBCMaps", isDirectory: true))
        }
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/PDFInspectorBCMaps", isDirectory: true)
        )
        guard let directory = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Adobe-Japan1-UCS2.bcmap").path)
        }) else { return }
        directory.path.withCString { path in
            _ = setenv("PDF_INSPECTOR_BCMAPS_DIR", path, 0)
        }
    }()
}

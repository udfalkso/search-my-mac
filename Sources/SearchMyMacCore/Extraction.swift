import AppKit
import Darwin
import Foundation
import PDFKit
import Vision

public struct ExtractedPassage: Sendable, Equatable {
    public var text: String
    public var ordinal: Int
    public var locationKind: StructuralLocationKind
    public var locationLabel: String?

    public init(text: String, ordinal: Int, locationKind: StructuralLocationKind, locationLabel: String?) {
        self.text = text
        self.ordinal = ordinal
        self.locationKind = locationKind
        self.locationLabel = locationLabel
    }
}

public struct ExtractedDocument: Sendable, Equatable {
    public var title: String?
    public var passages: [ExtractedPassage]
    public var availability: ContentAvailability
    public var error: String?

    public init(
        title: String? = nil,
        passages: [ExtractedPassage],
        availability: ContentAvailability = .available,
        error: String? = nil
    ) {
        self.title = title
        self.passages = passages
        self.availability = availability
        self.error = error
    }
}

public struct ExtractionLimits: Sendable {
    public var maximumSourceBytes: Int64 = 100 * 1_024 * 1_024
    public var maximumExtractedCharacters: Int = 20_000_000
    public var maximumOCRPages: Int = 100
    public var OCRMaximumDimension: CGFloat = 2_000

    public init() {}
}

public struct DocumentExtractor: Sendable {
    public static let supportedExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "csv", "tsv", "json", "jsonl", "xml", "yaml", "yml",
        "toml", "ini", "conf", "cfg", "log", "rtf", "rtfd", "html", "htm", "doc", "docx", "odt",
        "pdf", "pages", "numbers", "key", "ppt", "pptx", "odp", "xls", "xlsx", "xlsb", "ods",
        "epub", "eml", "emlx", "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "rs", "go",
        "py", "rb", "js", "jsx", "ts", "tsx", "java", "kt", "kts", "sh", "bash", "zsh", "fish",
        "sql", "css", "scss", "less", "tex"
    ]

    private let limits: ExtractionLimits
    private let chunker: PassageChunker

    public init(limits: ExtractionLimits = .init(), chunker: PassageChunker = .init()) {
        self.limits = limits
        self.chunker = chunker
    }

    public func extract(_ file: DiscoveredFile) async -> ExtractedDocument? {
        guard file.availability != .waitingForDownload else { return nil }
        let ext = file.url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else { return nil }
        guard file.size <= limits.maximumSourceBytes || ["pdf", "pages", "numbers", "key", "rtfd"].contains(ext) else {
            return ExtractedDocument(passages: [], availability: .filenameOnly, error: "File exceeds the extraction size limit")
        }

        do {
            switch ext {
            case "pdf":
                return try await extractPDF(file.url)
            case "rtf", "rtfd", "doc", "docx", "odt", "html", "htm":
                return try extractAttributedDocument(file.url, extension: ext)
            case "pages", "numbers", "key", "ppt", "pptx", "odp", "xls", "xlsx", "xlsb", "ods", "epub":
                return try await extractWithMetadataImporter(file.url)
            default:
                let data = try Data(contentsOf: file.url, options: [.mappedIfSafe])
                guard !looksBinary(data) else { return nil }
                let text = decodeText(data)
                return makeDocument(text: text, title: file.url.deletingPathExtension().lastPathComponent)
            }
        } catch {
            return ExtractedDocument(passages: [], availability: .extractionFailed, error: error.localizedDescription)
        }
    }

    private func extractPDF(_ url: URL) async throws -> ExtractedDocument {
        guard let document = PDFDocument(url: url) else {
            throw SearchMyMacError.extraction("PDFKit could not open the document")
        }
        if document.isLocked, !document.unlock(withPassword: "") {
            return ExtractedDocument(passages: [], availability: .contentLocked, error: "Password-protected PDF")
        }
        var passages: [ExtractedPassage] = []
        var ordinal = 0
        for pageIndex in 0..<document.pageCount {
            if Task.isCancelled { throw SearchMyMacError.cancelled }
            guard let page = document.page(at: pageIndex) else { continue }
            var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.count < 32, pageIndex < limits.maximumOCRPages, hasMeaningfulInk(page) {
                text = try await recognizeText(on: page)
            }
            for chunk in chunker.chunk(text) {
                passages.append(
                    ExtractedPassage(
                        text: chunk,
                        ordinal: ordinal,
                        locationKind: .page,
                        locationLabel: "Page \(pageIndex + 1)"
                    )
                )
                ordinal += 1
            }
        }
        return ExtractedDocument(
            title: document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
            passages: passages,
            availability: passages.isEmpty ? .filenameOnly : .available
        )
    }

    private func extractAttributedDocument(_ url: URL, extension ext: String) throws -> ExtractedDocument {
        let type: NSAttributedString.DocumentType = switch ext {
        case "rtf": .rtf
        case "rtfd": .rtfd
        case "doc": .docFormat
        case "docx": .officeOpenXML
        case "odt": .openDocument
        case "html", "htm": .html
        default: .plain
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: type,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        let value: NSAttributedString
        if ext == "rtfd" {
            value = try NSAttributedString(url: url, options: options, documentAttributes: nil)
        } else {
            // Reading HTML from Data deliberately supplies no base URL, preventing
            // the importer from resolving remote images, frames, or stylesheets.
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            value = try NSAttributedString(data: data, options: options, documentAttributes: nil)
        }
        return makeDocument(text: value.string, title: url.deletingPathExtension().lastPathComponent)
    }

    private func extractWithMetadataImporter(_ url: URL) async throws -> ExtractedDocument {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("searchmymac-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let temporaryURL = temporaryDirectory.appendingPathComponent("metadata.plist")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport")
        process.arguments = ["-t", "-d3", "-o", temporaryURL.path, url.path]
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try process.run()
        let finished = await wait(for: process, timeout: 30)
        guard finished else {
            process.terminate()
            if await wait(for: process, timeout: 2) == false, process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = await wait(for: process, timeout: 1)
            }
            throw SearchMyMacError.extraction("The macOS metadata importer timed out")
        }
        guard process.terminationStatus == 0 else {
            let data = try errorPipe.fileHandleForReading.readToEnd() ?? Data()
            throw SearchMyMacError.extraction(String(data: data, encoding: .utf8) ?? "Metadata importer failed")
        }
        let data = try Data(contentsOf: temporaryURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let dictionary = metadataDictionary(in: plist)
        let text: String
        if let value = dictionary?["kMDItemTextContent"] as? String {
            text = value
        } else if let values = dictionary?["kMDItemTextContent"] as? [String] {
            text = values.joined(separator: "\n")
        } else {
            text = ""
        }
        let title = dictionary?["kMDItemTitle"] as? String
        return makeDocument(text: text, title: title ?? url.deletingPathExtension().lastPathComponent)
    }

    private func metadataDictionary(in value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if dictionary["kMDItemTextContent"] != nil { return dictionary }
            for child in dictionary.values {
                if let match = metadataDictionary(in: child) { return match }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let match = metadataDictionary(in: child) { return match }
            }
        }
        return nil
    }

    private func makeDocument(text: String, title: String?) -> ExtractedDocument {
        let capped = String(text.prefix(limits.maximumExtractedCharacters))
        let passages = chunker.chunk(capped).enumerated().map {
            ExtractedPassage(text: $0.element, ordinal: $0.offset, locationKind: .section, locationLabel: nil)
        }
        return ExtractedDocument(title: title, passages: passages, availability: passages.isEmpty ? .filenameOnly : .available)
    }

    private func decodeText(_ data: Data) -> String {
        for encoding in [String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1, .macOSRoman] {
            if let value = String(data: data, encoding: encoding) { return value }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(8_192)
        guard !sample.isEmpty else { return false }
        let controlCount = sample.reduce(0) { count, byte in
            count + ((byte == 0 || (byte < 9) || (byte > 13 && byte < 32)) ? 1 : 0)
        }
        return Double(controlCount) / Double(sample.count) > 0.02
    }

    private func recognizeText(on page: PDFPage) async throws -> String {
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(limits.OCRMaximumDimension / max(bounds.width, bounds.height), 3)
        let size = CGSize(width: max(bounds.width * scale, 1), height: max(bounds.height * scale, 1))
        let image = page.thumbnail(of: size, for: .mediaBox)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let text = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n") ?? ""
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(cgImage: cgImage).perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func hasMeaningfulInk(_ page: PDFPage) -> Bool {
        let size = CGSize(width: 192, height: 192)
        let image = page.thumbnail(of: size, for: .mediaBox)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return false }
        let length = CFDataGetLength(data)
        guard length > 4 else { return false }
        let stride = max(cgImage.bitsPerPixel / 8, 1)
        var nonWhite = 0
        var samples = 0
        for index in Swift.stride(from: 0, to: length - stride, by: stride * 16) {
            let red = Int(bytes[index])
            let green = stride > 1 ? Int(bytes[index + 1]) : red
            let blue = stride > 2 ? Int(bytes[index + 2]) : red
            if min(red, green, blue) < 242 { nonWhite += 1 }
            samples += 1
        }
        return samples > 0 && Double(nonWhite) / Double(samples) > 0.005
    }

    private func wait(for process: Process, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = ProcessWaitGate(continuation)
            process.terminationHandler = { _ in gate.finish(true) }
            Task {
                do {
                    try await Task.sleep(for: .seconds(timeout))
                    gate.finish(false)
                } catch { }
            }
        }
    }
}

private final class ProcessWaitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: Bool) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

public struct PassageChunker: Sendable {
    public var targetWordCount: Int
    public var overlapWordCount: Int

    public init(targetWordCount: Int = 384, overlapWordCount: Int = 64) {
        self.targetWordCount = targetWordCount
        self.overlapWordCount = min(overlapWordCount, targetWordCount / 2)
    }

    public func chunk(_ text: String) -> [String] {
        let normalized = text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let paragraphs = normalized
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var words: [Substring] = []
        var chunks: [String] = []

        func flushIfNeeded(force: Bool = false) {
            while words.count >= targetWordCount || (force && !words.isEmpty) {
                let count = min(targetWordCount, words.count)
                chunks.append(words.prefix(count).joined(separator: " "))
                if count == words.count { words.removeAll(keepingCapacity: true); break }
                let removal = max(count - overlapWordCount, 1)
                words.removeFirst(removal)
            }
        }

        for paragraph in paragraphs {
            let paragraphWords = paragraph.split(whereSeparator: { $0.isWhitespace })
            if words.count + paragraphWords.count > targetWordCount { flushIfNeeded(force: true) }
            words.append(contentsOf: paragraphWords)
            flushIfNeeded()
        }
        flushIfNeeded(force: true)
        return chunks
    }
}

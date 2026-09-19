import AppKit
import Foundation
import Testing
@testable import SearchMyMacCore

@Test @MainActor func PDFExtractionYieldsAfterParsingBeforeProcessingPages() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("test.pdf")
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    let data = view.dataWithPDF(inside: view.bounds)
    try data.write(to: url)
    let gate = IndexingWorkGate()
    let completion = ExtractionCompletion()
    let extractor = DocumentExtractor(
        textRecognizer: UnusedRecognizer(),
        localDocumentParser: FocusDuringPDFParsing(gate: gate),
        workGate: gate
    )
    let task = Task {
        let result = await extractor.extract(DiscoveredFile(
            sourceID: "pdf", rootID: "root", url: url, modifiedAt: nil,
            size: Int64(data.count), availability: .available
        ))
        await completion.finish()
        return result
    }
    defer { gate.setSearchFieldFocused(false); task.cancel() }
    for _ in 0..<200 where !gate.shouldYieldToSearch {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(gate.shouldYieldToSearch)
    try await Task.sleep(for: .milliseconds(100))
    let finishedWhileFocused = await completion.finished
    #expect(!finishedWhileFocused)
    gate.setSearchFieldFocused(false)
    let result = await task.value
    #expect(result?.passages.first?.text == "A complete page of searchable fixture text after parsing.")
}

private actor ExtractionCompletion {
    var finished = false
    func finish() { finished = true }
}

private struct FocusDuringPDFParsing: LocalDocumentParsing {
    let gate: IndexingWorkGate
    func extractDocument(data: Data, fileExtension: String) throws -> String { "" }
    func extractPDF(data: Data) throws -> [StructuredPDFPage] {
        gate.setSearchFieldFocused(true)
        return [.init(pageIndex: 0, text: "A complete page of searchable fixture text after parsing.", needsOCR: false)]
    }
}

private struct UnusedRecognizer: OCRTextRecognizing {
    func recognizeText(in image: CGImage) async throws -> String { "" }
}

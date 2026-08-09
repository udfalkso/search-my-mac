import Foundation
import SearchMyMacCore

@main
struct SemanticBenchmark {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count == 3, let dimensions = Int(arguments[1]) else {
                throw BenchmarkError.usage
            }
            let embeddingModelURL = URL(fileURLWithPath: arguments[0])
            let generatorModelURL = URL(fileURLWithPath: arguments[2])
            let extractedText = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !extractedText.isEmpty else { throw BenchmarkError.emptyInput }
            let filename = "Falkson and Davis 4600 Overbrook Road $1.5M and $700k to close MoCo MD.pdf"
            let path = "/Users/udi/Documents/2022 Home Purchase : Mortgage/Legacy:Old Documents"

            print("Loading \(generatorModelURL.lastPathComponent) for automatic card generation…")
            let generatorStarted = Date()
            let generator = try QwenDocumentCardGenerator(
                url: generatorModelURL,
                maximumTokens: 2_048,
                useGPU: true,
                suppressLogs: true
            )
            let generatedCard = try generator.generate(filename: filename, path: path, extractedText: extractedText)
            generator.shutdown()
            print("Generated in \(String(format: "%.2f", Date().timeIntervalSince(generatorStarted)))s")
            print("\nAUTOMATIC DOCUMENT CARD\n\(generatedCard)\n")

            let modelURL = embeddingModelURL
            print("Loading \(modelURL.lastPathComponent) at \(dimensions) dimensions…")
            let loadStarted = Date()
            let model = try QwenEmbeddingModel(
                url: modelURL,
                dimensions: dimensions,
                maximumTokens: 2_048,
                useGPU: true,
                suppressLogs: true
            )
            defer { model.shutdown() }
            print("Loaded in \(String(format: "%.2f", Date().timeIntervalSince(loadStarted)))s")

            let query = "home buying related"
            let raw = extractedText
            let titleAndRaw = "Document title: \(filename)\n\nDocument passage:\n\(raw)"
            let card = "Document topic: home purchase and residential real-estate transaction. This document is a mortgage financing and closing-cost estimate for buying a home. Concepts: home buying, home purchase, mortgage loan, financing, cash to close, monthly payment, closing costs, sale price, title insurance, homeowner insurance."
            let decoy = "Search My Mac application settings, semantic indexing preferences, privacy controls, appearance, storage totals, and account options."

            let queryVector = try model.embedQuery(query)
            func score(_ label: String, _ text: String) throws {
                let vector = try model.embedDocument(text)
                let cosine = zip(queryVector, vector).reduce(Float.zero) { $0 + $1.0 * $1.1 }
                print("\(label): \(String(format: "%.6f", cosine))")
            }
            try score("raw passage", raw)
            try score("title + passage", titleAndRaw)
            try score("document card", card)
            try score("automatic document card", generatedCard)
            for line in generatedCard.split(separator: "\n").map(String.init) where !line.isEmpty {
                let label = line.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "generated field"
                try score("automatic \(label.lowercased())", line)
            }
            try score("irrelevant decoy", decoy)
        } catch {
            FileHandle.standardError.write(Data("semantic-benchmark: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

private enum BenchmarkError: LocalizedError {
    case usage
    case emptyInput
    var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: semantic-benchmark EMBEDDING_MODEL_PATH DIMENSIONS GENERATOR_MODEL_PATH < EXTRACTED_TEXT"
        case .emptyInput:
            "The benchmark requires the exact extracted document text on standard input."
        }
    }
}

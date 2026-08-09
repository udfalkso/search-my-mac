import Darwin
import Foundation
import SearchMyMacCore

private enum CLIOutputFormat: String {
    case json
    case jsonl
    case paths
    case text
}

private struct CLIOptions {
    var query = ""
    var mode: SearchMode = .text
    var limit = 10
    var pathPrefixes: Set<String> = []
    var extensions: Set<String> = []
    var modifiedAfter: Date?
    var modifiedBefore: Date?
    var semanticWeight = SearchRequest.defaultHybridSemanticWeight
    var output: CLIOutputFormat = .json

    static func parse(_ arguments: [String]) throws -> CLIOptions {
        var options = CLIOptions()
        var position = 0
        var queryParts: [String] = []
        let arguments = arguments.first == "search" ? Array(arguments.dropFirst()) : arguments

        func value(after flag: String) throws -> String {
            let next = position + 1
            guard next < arguments.count else { throw CLIError.usage("Missing value after \(flag).") }
            position = next
            return arguments[next]
        }

        while position < arguments.count {
            let argument = arguments[position]
            switch argument {
            case "-h", "--help":
                throw CLIError.help
            case "--mode":
                let raw = try value(after: argument)
                guard let mode = SearchMode(rawValue: raw) else {
                    throw CLIError.usage("Mode must be text, semantic, or hybrid.")
                }
                options.mode = mode
            case "-n", "--limit":
                let raw = try value(after: argument)
                guard let limit = Int(raw), (1...200).contains(limit) else {
                    throw CLIError.usage("Limit must be between 1 and 200.")
                }
                options.limit = limit
            case "--path":
                let raw = NSString(string: try value(after: argument)).expandingTildeInPath
                options.pathPrefixes.insert(URL(fileURLWithPath: raw).standardizedFileURL.path)
            case "--type", "--types":
                let values = try value(after: argument).split(separator: ",")
                options.extensions.formUnion(values.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
            case "--after":
                options.modifiedAfter = try parseDate(value(after: argument), flag: argument)
            case "--before":
                options.modifiedBefore = try parseDate(value(after: argument), flag: argument)
            case "--semantic-weight":
                let raw = try value(after: argument)
                guard let weight = Double(raw), (0...1).contains(weight) else {
                    throw CLIError.usage("Semantic weight must be between 0 and 1.")
                }
                options.semanticWeight = weight
            case "--format":
                let raw = try value(after: argument)
                guard let format = CLIOutputFormat(rawValue: raw) else {
                    throw CLIError.usage("Format must be json, jsonl, paths, or text.")
                }
                options.output = format
            case "--json": options.output = .json
            case "--jsonl": options.output = .jsonl
            case "--paths": options.output = .paths
            case "--text": options.output = .text
            case "--":
                queryParts.append(contentsOf: arguments.dropFirst(position + 1))
                position = arguments.count
                continue
            default:
                if argument.hasPrefix("-") {
                    throw CLIError.usage("Unknown option: \(argument)")
                }
                queryParts.append(argument)
            }
            position += 1
        }

        options.query = queryParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !options.query.isEmpty else { throw CLIError.usage("A search query is required.") }
        return options
    }

    private static func parseDate(_ value: String, flag: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        if let date = formatter.date(from: value) { return date }
        let fullFormatter = ISO8601DateFormatter()
        if let date = fullFormatter.date(from: value) { return date }
        throw CLIError.usage("\(flag) expects YYYY-MM-DD or an ISO-8601 timestamp.")
    }
}

private enum CLIError: LocalizedError {
    case help
    case usage(String)

    var errorDescription: String? {
        switch self {
        case .help: nil
        case .usage(let message): message
        }
    }
}

private struct CLIEnvelope: Encodable {
    let query: String
    let requestedMode: String
    let effectiveMode: String
    let enhancedSemantic: Bool
    let resultCount: Int
    let results: [CLIResult]

    enum CodingKeys: String, CodingKey {
        case query
        case requestedMode = "requested_mode"
        case effectiveMode = "effective_mode"
        case enhancedSemantic = "enhanced_semantic"
        case resultCount = "result_count"
        case results
    }
}

private struct CLIResult: Encodable {
    let path: String
    let filename: String
    let fileType: String
    let modifiedAt: String?
    let score: Double
    let snippets: [CLISnippet]

    enum CodingKeys: String, CodingKey {
        case path, filename, score, snippets
        case fileType = "file_type"
        case modifiedAt = "modified_at"
    }
}

private struct CLISnippet: Encodable {
    let location: String?
    let text: String
}

@main
private struct SearchMyMacCLI {
    static func main() async {
        do {
            let options = try CLIOptions.parse(Array(CommandLine.arguments.dropFirst()))
            let engine = try LocalSearchEngine(readOnly: true)
            await engine.setHistoryRecording(false)
            if options.mode != .text {
                // Command-line callers frequently run inside automation
                // sandboxes that cannot create Metal command queues.
                try await engine.prepareSemanticSearch(useGPU: false, suppressLogs: true)
            }
            let filters = SearchFilters(
                pathPrefixes: options.pathPrefixes,
                extensions: options.extensions,
                modifiedAfter: options.modifiedAfter,
                modifiedBefore: options.modifiedBefore
            )
            let response = try await engine.search(SearchRequest(
                query: options.query,
                mode: options.mode,
                filters: filters,
                hybridSemanticWeight: options.semanticWeight,
                limit: options.limit
            ))
            let results = response.hits.map(makeResult)
            let semanticStatus = await engine.semanticStatus()
            try writeResults(
                results,
                query: options.query,
                requestedMode: options.mode,
                effectiveMode: response.effectiveMode,
                enhancedSemantic: semanticStatus.enhancedUnderstandingInstalled,
                format: options.output
            )
            await engine.shutdown()
            Darwin._exit(EXIT_SUCCESS)
        } catch CLIError.help {
            write(usage, to: .standardOutput)
            Darwin._exit(EXIT_SUCCESS)
        } catch CLIError.usage(let message) {
            write("smm: \(message)\n\n\(usage)", to: .standardError)
            Darwin._exit(2)
        } catch {
            write("smm: \(error.localizedDescription)\n", to: .standardError)
            Darwin._exit(1)
        }
    }

    private static func makeResult(_ hit: SearchHit) -> CLIResult {
        CLIResult(
            path: hit.url.path,
            filename: hit.filename,
            fileType: hit.fileExtension,
            modifiedAt: hit.modifiedAt.map { ISO8601DateFormatter().string(from: $0) },
            score: hit.score,
            snippets: hit.snippets.map {
                CLISnippet(
                    location: $0.locationLabel,
                    text: $0.text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        )
    }

    private static func writeResults(
        _ results: [CLIResult],
        query: String,
        requestedMode: SearchMode,
        effectiveMode: SearchMode,
        enhancedSemantic: Bool,
        format: CLIOutputFormat
    ) throws {
        switch format {
        case .json:
            let envelope = CLIEnvelope(
                query: query,
                requestedMode: requestedMode.rawValue,
                effectiveMode: effectiveMode.rawValue,
                enhancedSemantic: enhancedSemantic,
                resultCount: results.count,
                results: results
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(envelope)
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
        case .jsonl:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            for result in results {
                var data = try encoder.encode(result)
                data.append(0x0A)
                FileHandle.standardOutput.write(data)
            }
        case .paths:
            write(results.map(\.path).joined(separator: "\n") + (results.isEmpty ? "" : "\n"), to: .standardOutput)
        case .text:
            let output = results.enumerated().map { index, result in
                let snippets = result.snippets.prefix(3).map {
                    "    \($0.location.map { "[\($0)] " } ?? "")\($0.text)"
                }.joined(separator: "\n")
                return "\(index + 1). \(result.path)\n\(snippets)"
            }.joined(separator: "\n\n")
            write(output + (output.isEmpty ? "" : "\n"), to: .standardOutput)
        }
    }

    private static func write(_ string: String, to handle: FileHandle) {
        handle.write(Data(string.utf8))
    }

    private static let usage = """
    Usage: smm [search] <query> [options]

    Search the local Search My Mac index. JSON is emitted by default.

      --mode text|semantic|hybrid   Search mode (default: text)
      -n, --limit N                 Maximum results, 1–200 (default: 10)
      --path DIR                    Restrict to a folder; repeatable
      --type EXT[,EXT...]           Restrict file types; repeatable
      --after DATE                  Modified on/after YYYY-MM-DD
      --before DATE                 Modified before YYYY-MM-DD
      --semantic-weight 0...1       Hybrid meaning weight (default: 0.35)
      --format json|jsonl|paths|text
      --json | --jsonl | --paths | --text

    Examples:
      smm "quarterly revenue"
      smm "Maryland license" --mode hybrid --type pdf --limit 5
      smm "project launch notes" --path ~/Documents --jsonl
    """
}

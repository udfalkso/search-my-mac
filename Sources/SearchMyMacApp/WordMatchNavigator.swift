import AppKit
import Foundation
import SearchMyMacCore

@MainActor
final class WordMatchNavigator {
    enum NavigationResult {
        case found
        case notFound
        case notReady
        case failed
    }

    private static let wordBundleIdentifier = "com.microsoft.Word"
    private static let wordExtensions: Set<String> = ["doc", "docx", "docm"]
    private lazy var wordApplicationURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: Self.wordBundleIdentifier
    )

    func canNavigate(_ hit: SearchHit) -> Bool {
        let fileExtension = hit.fileExtension.lowercased()
        guard Self.wordExtensions.contains(fileExtension),
              !Self.searchAnchors(for: hit).isEmpty else { return false }
        return wordApplicationURL != nil
    }

    func openInWord(_ documentURL: URL) -> Bool {
        guard let wordApplicationURL else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [documentURL],
            withApplicationAt: wordApplicationURL,
            configuration: configuration
        )
        return true
    }

    func navigate(documentURL: URL, anchors: [String]) -> NavigationResult {
        guard !anchors.isEmpty else { return .notFound }
        let source = Self.appleScriptSource(documentURL: documentURL, anchors: anchors)
        guard let script = NSAppleScript(source: source) else { return .failed }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        guard error == nil, let result = descriptor.stringValue else { return .failed }
        return switch result {
        case "found": .found
        case "not-found": .notFound
        case "not-ready": .notReady
        default: .failed
        }
    }

    static func searchAnchors(for hit: SearchHit) -> [String] {
        guard let snippet = hit.snippets.first else { return [] }
        return searchAnchors(for: snippet)
    }

    static func searchAnchors(for snippet: SearchSnippet) -> [String] {
        let highlightedText = firstHighlightedText(in: snippet)
        let segments = snippet.text
            .replacingOccurrences(of: "...", with: "…")
            .components(separatedBy: "…")
            .map(normalizeWhitespace)
            .filter { !$0.isEmpty }
        guard !segments.isEmpty else { return [] }

        let orderedSegments = segments.sorted { lhs, rhs in
            let lhsContainsHighlight = highlightedText.map { contains($0, in: lhs) } ?? false
            let rhsContainsHighlight = highlightedText.map { contains($0, in: rhs) } ?? false
            if lhsContainsHighlight != rhsContainsHighlight { return lhsContainsHighlight }
            return lhs.count > rhs.count
        }

        var anchors: [String] = []
        for segment in orderedSegments.prefix(3) {
            let words = segment.split(whereSeparator: \Character.isWhitespace).map(String.init)
            guard words.count >= 3 else { continue }
            let center = highlightedText.flatMap { highlightedWordIndex($0, in: words) }
                ?? min(words.count / 2, words.count - 1)
            for windowSize in [18, 12, 8, 5] {
                let count = min(windowSize, words.count)
                let centeredStart = min(max(center - count / 2, 0), words.count - count)
                let starts = [centeredStart, min(center, words.count - count), max(center - count + 1, 0)]
                for start in starts {
                    let candidate = words[start..<(start + count)].joined(separator: " ")
                    let bounded = boundedAnchor(candidate)
                    if bounded.count >= 12, !anchors.contains(bounded) {
                        anchors.append(bounded)
                    }
                }
            }
        }
        return Array(anchors.prefix(12))
    }

    private static func firstHighlightedText(in snippet: SearchSnippet) -> String? {
        let text = snippet.text as NSString
        for highlight in snippet.highlights {
            let range = NSRange(location: highlight.location, length: highlight.length)
            guard range.location != NSNotFound,
                  range.location >= 0,
                  range.length > 0,
                  NSMaxRange(range) <= text.length else { continue }
            let value = text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func highlightedWordIndex(_ highlight: String, in words: [String]) -> Int? {
        let foldedHighlight = folded(highlight)
        guard !foldedHighlight.isEmpty else { return nil }
        return words.firstIndex { folded($0).contains(foldedHighlight) }
    }

    private static func contains(_ needle: String, in haystack: String) -> Bool {
        folded(haystack).contains(folded(needle))
    }

    private static func folded(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func normalizeWhitespace(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func boundedAnchor(_ value: String, maximumUTF16Length: Int = 180) -> String {
        let text = value as NSString
        guard text.length > maximumUTF16Length else { return value }
        let prefix = text.substring(to: maximumUTF16Length) as NSString
        let lastSpace = prefix.range(of: " ", options: .backwards).location
        guard lastSpace != NSNotFound, lastSpace >= 12 else { return prefix as String }
        return prefix.substring(to: lastSpace)
    }

    private static func appleScriptSource(documentURL: URL, anchors: [String]) -> String {
        let path = appleScriptLiteral(documentURL.path)
        let anchorList = anchors.map(appleScriptLiteral).joined(separator: ", ")
        return """
        tell application id "com.microsoft.Word"
            set targetFile to POSIX file \(path)
            set targetDocument to missing value
            repeat with candidateWindow in windows
                try
                    set candidateDocument to document of candidateWindow
                    if (full name of candidateDocument) is targetFile then
                        set targetDocument to candidateDocument
                        exit repeat
                    end if
                end try
            end repeat
            if targetDocument is missing value then return "not-ready"

            activate
            activate object targetDocument
            set selection start of selection to 0
            set selection end of selection to 0
            repeat with candidateText in {\(anchorList)}
                set matchFinder to find object of selection
                tell matchFinder
                    clear formatting
                    set didFind to execute find find text (contents of candidateText) wrap find stop with match forward without find format
                end tell
                if didFind then
                    activate object targetDocument
                    return "found"
                end if
                set selection start of selection to 0
                set selection end of selection to 0
            end repeat
            return "not-found"
        end tell
        """
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}

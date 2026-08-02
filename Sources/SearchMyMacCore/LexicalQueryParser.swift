import Foundation

public struct LexicalQueryParser: Sendable {
    public init() {}

    public func parse(_ input: String) throws -> String {
        let tokens = tokenize(input)
        guard !tokens.isEmpty else { throw SearchMyMacError.invalidQuery("Enter a word or phrase") }

        var positive: [String] = []
        var negative: [String] = []
        var joinWithOR = false

        for token in tokens {
            if token.uppercased() == "OR" {
                joinWithOR = true
                continue
            }
            let isNegative = token.hasPrefix("-")
            let raw = isNegative ? String(token.dropFirst()) : token
            guard !raw.isEmpty else { continue }
            let normalized = normalize(raw)
            guard !normalized.isEmpty else { continue }
            if isNegative {
                negative.append(normalized)
            } else {
                positive.append(normalized)
            }
        }

        guard !positive.isEmpty else {
            throw SearchMyMacError.invalidQuery("A search cannot contain only excluded terms")
        }

        let separator = joinWithOR ? " OR " : " AND "
        var expression = positive.joined(separator: separator)
        for term in negative {
            expression = "(\(expression)) NOT \(term)"
        }
        return expression
    }

    public func highlightTerms(_ input: String) -> [String] {
        tokenize(input)
            .filter { $0.uppercased() != "OR" && !$0.hasPrefix("-") }
            .map { token in
                var value = token
                if let colon = value.firstIndex(of: ":") { value = String(value[value.index(after: colon)...]) }
                return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"*"))
            }
            .filter { !$0.isEmpty }
    }

    private func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for character in input {
            if character == "\"" {
                current.append(character)
                quoted.toggle()
            } else if character.isWhitespace && !quoted {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private func normalize(_ token: String) -> String {
        let fieldMap = ["name": "filename", "path": "path", "title": "title"]
        var field: String?
        var value = token
        if let colon = token.firstIndex(of: ":") {
            let requested = String(token[..<colon]).lowercased()
            if let mapped = fieldMap[requested] {
                field = mapped
                value = String(token[token.index(after: colon)...])
            }
        }

        let isPhrase = value.hasPrefix("\"") && value.hasSuffix("\"") && value.count > 1
        let allowsPrefix = value.hasSuffix("*") && !isPhrase
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"*"))
        value = value.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" || $0 == " " }
            .map(String.init)
            .joined()
        guard !value.isEmpty else { return "" }
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        let queryValue = isPhrase || value.contains(" ") ? "\"\(escaped)\"" : "\"\(escaped)\"\(allowsPrefix ? "*" : "")"
        return field.map { "\($0):\(queryValue)" } ?? queryValue
    }
}

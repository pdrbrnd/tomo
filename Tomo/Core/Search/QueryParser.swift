import Foundation

/// Parses search-bar input into a structured `PluginQuery`.
///
/// Grammar (Calibre / GitHub-style):
/// - Free text → goes into `text` (everything that doesn't match a field).
/// - `field:value` → maps to the matching field. Unknown fields stay in `text`.
/// - `field:"quoted value with spaces"` → preserves the value as one token.
/// - Bare `"quoted phrase"` (no field prefix) → joined into `text` as a phrase.
/// - AND is implicit (everything must match). No OR / NOT / parentheses.
///
/// Supported fields:
///   `title`, `author`, `language` (aliases `lang`, `locale`), `isbn`,
///   `format` (alias `ext`), `year`, `publisher`.
///
/// Example: `"ensaio sobre" author:saramago language:pt format:epub`
enum QueryParser {

    static func parse(_ input: String) -> PluginQuery {
        let tokens = tokenize(input)
        var freeText: [String] = []
        var title: String?
        var author: String?
        var language: String?
        var isbn: String?
        var format: String?
        var year: Int?
        var publisher: String?

        for token in tokens {
            guard let (field, value) = splitField(token), !value.isEmpty else {
                if isbn == nil, let detected = extractISBN(from: token.value) {
                    isbn = detected
                } else {
                    freeText.append(token.value)
                }
                continue
            }
            switch field {
            case "title": title = value
            case "author", "authors": author = value
            case "language", "lang", "locale": language = value
            case "isbn": isbn = value
            case "format", "ext", "extension": format = value.lowercased()
            case "year": year = Int(value)
            case "publisher": publisher = value
            default:
                // Unknown field — preserve original token as free text so the
                // user can see we didn't lose it.
                freeText.append("\(field):\(value)")
            }
        }

        return PluginQuery(
            text: freeText.joined(separator: " "),
            title: title,
            author: author,
            language: language,
            isbn: isbn,
            format: format,
            year: year,
            publisher: publisher)
    }

    // MARK: - Tokenisation

    /// One token from the search bar. `value` is the unquoted content;
    /// `wasQuoted` distinguishes `"hello world"` from `hello world`.
    private struct Token {
        let value: String
        let wasQuoted: Bool
    }

    /// Splits the input on whitespace, treating double-quoted spans as a
    /// single token. Trailing-or-stray quotes are tolerated — the half-open
    /// quote behaves like an unquoted run.
    private static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var inQuotes = false
        var wasQuoted = false

        func flush() {
            if !current.isEmpty {
                tokens.append(Token(value: current, wasQuoted: wasQuoted))
            }
            current = ""
            wasQuoted = false
        }

        for char in input {
            if char == "\"" {
                if inQuotes {
                    inQuotes = false
                    wasQuoted = true
                    flush()
                } else {
                    flush()
                    inQuotes = true
                }
                continue
            }
            if char.isWhitespace, !inQuotes {
                flush()
                continue
            }
            current.append(char)
        }
        flush()
        return tokens
    }

    /// Returns a normalized ISBN (digits-only for 13; uppercased for 10) if
    /// `raw` is a checksum-valid ISBN-10 or ISBN-13 after stripping hyphens
    /// and spaces. Without the checksum step, plain `\d{10,13}` matches lots
    /// of non-ISBN strings (timestamps, EANs, scanned-PDF page numbers).
    private static func extractISBN(from raw: String) -> String? {
        let stripped = raw.filter { $0 != "-" && $0 != " " }
        if stripped.count == 13,
            stripped.hasPrefix("978") || stripped.hasPrefix("979"),
            stripped.allSatisfy(\.isNumber),
            isValidISBN13(stripped)
        {
            return stripped
        }
        if stripped.count == 10 {
            let upper = stripped.uppercased()
            let chars = Array(upper)
            let headOK = chars.prefix(9).allSatisfy { $0.isNumber }
            let tailOK = chars.last.map { $0.isNumber || $0 == "X" } == true
            if headOK, tailOK, isValidISBN10(upper) {
                return upper
            }
        }
        return nil
    }

    private static func isValidISBN13(_ s: String) -> Bool {
        let digits = s.compactMap { $0.wholeNumberValue }
        guard digits.count == 13 else { return false }
        var sum = 0
        for i in 0..<13 {
            sum += digits[i] * (i.isMultiple(of: 2) ? 1 : 3)
        }
        return sum % 10 == 0
    }

    private static func isValidISBN10(_ s: String) -> Bool {
        let chars = Array(s)
        guard chars.count == 10 else { return false }
        var sum = 0
        for i in 0..<10 {
            let c = chars[i]
            let v: Int
            if c == "X" {
                v = 10
            } else if let d = c.wholeNumberValue {
                v = d
            } else {
                return false
            }
            sum += v * (10 - i)
        }
        return sum % 11 == 0
    }

    /// Splits `field:value` into (field, value). Returns nil if the token
    /// doesn't have a field prefix or the field name is empty. Quoted tokens
    /// (`"phrase"`) are intentionally never treated as field tokens — the
    /// quote signals "treat as literal phrase".
    private static func splitField(_ token: Token) -> (String, String)? {
        guard !token.wasQuoted, let colonIndex = token.value.firstIndex(of: ":") else {
            return nil
        }
        let field = String(token.value[..<colonIndex]).lowercased()
        let value = String(token.value[token.value.index(after: colonIndex)...])
        guard !field.isEmpty, field.allSatisfy({ $0.isLetter || $0 == "_" }) else {
            // Tokens like `https://foo` or `12:00` shouldn't be treated as
            // field tokens. We require a pure-letter field name.
            return nil
        }
        return (field, value)
    }
}

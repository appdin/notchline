import Foundation

/// Decoding and line splitting for text responses such as CSV. Every provider that parses text
/// rather than JSON goes through here, so line endings and encoding quirks are handled once.
///
/// Swift treats "\r\n" as a single `Character`, so `split(separator: "\n")` and
/// `contains("\n")` never match a CRLF file. Splitting on `isNewline` covers LF, CRLF and a
/// lone CR alike.
enum TextResponse {
    /// UTF-8 text without a leading byte order mark.
    static func text(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    /// Non-empty lines, whatever the line endings.
    static func lines(_ data: Data) -> [Substring] {
        lines(text(data))
    }

    static func lines(_ text: String) -> [Substring] {
        text.split(whereSeparator: \.isNewline)
    }

    /// The first line, or nil when the text has no line break yet, as in a truncated range request.
    static func firstCompleteLine(_ data: Data) -> Substring? {
        let text = text(data)
        guard text.contains(where: \.isNewline) else { return nil }
        return lines(text).first
    }

    /// Comma-separated fields, keeping empty ones so columns stay aligned. Values are not
    /// quoted in the sources used so far; quoted fields would need a real CSV parser.
    static func fields(_ line: Substring, separator: Character = ",") -> [Substring] {
        line.split(separator: separator, omittingEmptySubsequences: false)
    }
}

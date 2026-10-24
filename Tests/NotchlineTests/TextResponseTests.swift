import Foundation
import Testing
@testable import NotchlineCore

struct TextResponseTests {
    @Test(arguments: [
        "a,1\nb,2\n",
        "a,1\r\nb,2\r\n",
        "a,1\rb,2\r",
        "a,1\r\nb,2\n",
        "\u{FEFF}a,1\r\nb,2",
    ])
    func linesIgnoreLineEndingsAndByteOrderMark(text: String) {
        #expect(TextResponse.lines(Data(text.utf8)) == ["a,1", "b,2"])
    }

    @Test func firstCompleteLineNeedsALineBreak() {
        #expect(TextResponse.firstCompleteLine(Data("DATE(UTC),3A20P Callaghan Creek\r\n2026".utf8)) == "DATE(UTC),3A20P Callaghan Creek")
        #expect(TextResponse.firstCompleteLine(Data("DATE(UTC),3A20P Callag".utf8)) == nil)
        #expect(TextResponse.firstCompleteLine(Data("\u{FEFF}DATE(UTC)\n".utf8)) == "DATE(UTC)")
    }

    @Test func fieldsKeepEmptyColumns() {
        #expect(TextResponse.fields("2026-01-07 00:00,,5.0,") == ["2026-01-07 00:00", "", "5.0", ""])
    }

    /// Text parsing goes through `TextResponse` so every data source handles CRLF, lone CR and a
    /// byte order mark. This fails if a file in NotchlineCore splits on "\n" or decodes text itself.
    @Test func sourcesUseTextResponseForText() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/NotchlineCore")
        let forbidden = [#"separator: "\n""#, #"separatedBy: "\n""#, #"separatedBy: .newlines"#,
                         #"contains("\n")"#, #"String(decoding:"#, #"String(data:"#]
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "TextResponse.swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for pattern in forbidden where text.contains(pattern) {
                Issue.record("\(file.lastPathComponent) uses \(pattern); parse text with TextResponse instead")
            }
        }
    }
}

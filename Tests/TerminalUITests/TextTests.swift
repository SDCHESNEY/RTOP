import Testing
@testable import TerminalUI

@Suite struct TextSanitizerTests {
    @Test func escapeSequencesCannotSurvive() {
        let hostile = "evil\u{1B}[2J\u{1B}]0;pwned\u{07}name"
        let clean = TextSanitizer.sanitize(hostile)
        #expect(!clean.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x07 })
        #expect(clean == "evil?[2J?]0;pwned?name")
    }

    @Test(arguments: [0x00, 0x08, 0x0A, 0x0D, 0x1B, 0x7F, 0x80, 0x9B, 0x9F, 0x2028, 0x2029, 0x202E, 0x2066, 0x200F, 0x061C])
    func controlAndBidiScalarsAreReplaced(value: Int) throws {
        let scalar = try #require(Unicode.Scalar(UInt32(value)))
        #expect(TextSanitizer.sanitize("a\(scalar)b") == "a?b")
    }

    @Test func ordinaryAndInternationalTextIsUntouched() {
        for text in ["Safari", "日本語", "Ünïcödé", "emoji 😀", "tab\u{FFFD}replacement"] {
            #expect(TextSanitizer.sanitize(text) == text)
        }
    }

    @Test func overlongInputIsBounded() {
        let long = String(repeating: "x", count: 1_000_000)
        #expect(TextSanitizer.sanitize(long).unicodeScalars.count == TextSanitizer.maxScalars)
    }

    @Test func invalidUTF8DecodedLossilyIsSafe() {
        let name = String(decoding: [0x66, 0xFF, 0xFE, 0x6F], as: UTF8.self)
        #expect(TextSanitizer.sanitize(name) == name)
    }
}

@Suite struct DisplayWidthTests {
    @Test func widths() {
        #expect(DisplayWidth.of("a") == 1)
        #expect(DisplayWidth.of("日") == 2)
        #expect(DisplayWidth.of("한") == 2)
        #expect(DisplayWidth.of("😀") == 2)
        #expect(DisplayWidth.of("e\u{0301}") == 1) // combining accent adds no column
        #expect(DisplayWidth.of("—") == 1)
        #expect(DisplayWidth.of("日本語") == 6)
        #expect(DisplayWidth.of("\u{200B}") == 1) // a bare zero-width cluster still occupies a cell
    }

    @Test func truncationNeverSplitsWideCharacters() {
        #expect(DisplayWidth.truncate("日本語", toColumns: 5) == "日本")
        #expect(DisplayWidth.truncate("日本語", toColumns: 1) == "")
        #expect(DisplayWidth.truncate("abcdef", toColumns: 4, ellipsis: true) == "abc…")
        #expect(DisplayWidth.truncate("日本語abc", toColumns: 5, ellipsis: true) == "日本…")
        #expect(DisplayWidth.truncate("abc", toColumns: 5, ellipsis: true) == "abc")
        #expect(DisplayWidth.truncate("abc", toColumns: 0) == "")
    }

    @Test func truncationKeepsCombiningMarksWithTheirBase() {
        #expect(DisplayWidth.truncate("e\u{0301}e\u{0301}e\u{0301}", toColumns: 2) == "e\u{0301}e\u{0301}")
    }
}

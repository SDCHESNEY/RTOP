import Testing
@testable import TerminalUI

/// Minimal terminal emulator for the subset of sequences the renderer emits
/// (CUP, SGR, ED, printable text), used to prove diffs reproduce the frame.
private struct FakeScreen {
    var columns: Int
    var rows: Int
    var grid: [[Character]]
    var x = 0, y = 0

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        grid = Array(repeating: Array(repeating: " ", count: columns), count: rows)
    }

    mutating func apply(_ output: String) {
        // Iterate grapheme clusters: a real terminal composes combining marks onto their base.
        var chars = Array(output)[...]
        while let ch = chars.popFirst() {
            if ch == "\u{1B}" {
                guard chars.popFirst() == "[" else { continue }
                var params = ""
                while let c = chars.popFirst() {
                    if let a = c.asciiValue, (0x40...0x7E).contains(a) {
                        handleCSI(params, final: c)
                        break
                    }
                    params.append(c)
                }
            } else {
                guard y < rows, x < columns else { continue }
                grid[y][x] = ch
                let w = DisplayWidth.of(ch)
                if w == 2, x + 1 < columns { grid[y][x + 1] = "\u{0}" }
                x += w
            }
        }
    }

    private mutating func handleCSI(_ params: String, final: Character) {
        switch final {
        case "H":
            let parts = params.split(separator: ";").compactMap { Int($0) }
            y = (parts.first ?? 1) - 1
            x = (parts.count > 1 ? parts[1] : 1) - 1
        case "J":
            if params == "2" { grid = Array(repeating: Array(repeating: " ", count: columns), count: rows) }
        default: break // SGR and others do not affect glyph placement
        }
    }

    func text(_ row: Int) -> String { String(grid[row].filter { $0 != "\u{0}" }) }
}

@Suite struct ScreenRendererTests {
    private func buffer(_ lines: [String], style: Style = .plain) -> CellBuffer {
        var b = CellBuffer(columns: lines.map { DisplayWidth.of($0) }.max() ?? 0, rows: lines.count)
        for (y, line) in lines.enumerated() { b.write(line, x: 0, y: y, style: style) }
        return b
    }

    private func assertScreen(_ screen: FakeScreen, matches b: CellBuffer, sourceLocation: SourceLocation = #_sourceLocation) {
        for y in 0..<b.rows {
            #expect(screen.text(y) == b.rowText(y), "row \(y)", sourceLocation: sourceLocation)
        }
    }

    @Test func firstFrameClearsAndPaints() {
        var r = ScreenRenderer()
        let b = buffer(["hello", "world"])
        let out = r.frame(for: b)
        #expect(out.contains("\u{1B}[2J"))
        var screen = FakeScreen(columns: 5, rows: 2)
        screen.apply(out)
        assertScreen(screen, matches: b)
    }

    @Test func identicalFrameProducesNoCursorMovesOrText() {
        var r = ScreenRenderer()
        let b = buffer(["hello", "world"])
        _ = r.frame(for: b)
        let second = r.frame(for: b)
        #expect(!second.contains("H"))
        #expect(!second.contains("hello"))
        #expect(!second.contains("\u{1B}[2J"))
    }

    @Test func onlyChangedSpanIsEmitted() {
        var r = ScreenRenderer()
        _ = r.frame(for: buffer(["hello world", "second row!"]))
        let out = r.frame(for: buffer(["hello World", "second row!"]))
        #expect(out.contains("\u{1B}[1;7H"))
        #expect(out.contains("W"))
        #expect(!out.contains("second"))
        #expect(!out.contains("hello"))
    }

    @Test func diffsReproduceTheFrameOverASequence() {
        var r = ScreenRenderer()
        var screen = FakeScreen(columns: 12, rows: 3)
        let frames: [[String]] = [
            ["alpha", "beta", "gamma"],
            ["alpha", "BETA", "gamma"],
            ["", "", ""],
            ["日本語 x", "a日b", "e\u{0301}x"],
            ["日本語 x", "a日b", "e\u{0301}y"],
            ["日本x x", "ab日", "ex"],       // wide chars replaced by narrow ones and vice versa
            ["x", "", "   zz"],
        ]
        for lines in frames {
            var b = CellBuffer(columns: 12, rows: 3)
            for (y, line) in lines.enumerated() { b.write(line, x: 0, y: y) }
            screen.apply(r.frame(for: b))
            assertScreen(screen, matches: b)
        }
    }

    @Test func wideCharacterReplacedByNarrowOnesRepaintsBothColumns() {
        var r = ScreenRenderer()
        var screen = FakeScreen(columns: 4, rows: 1)
        var wide = CellBuffer(columns: 4, rows: 1); wide.write("日", x: 0, y: 0)
        var narrow = CellBuffer(columns: 4, rows: 1); narrow.write("ab", x: 0, y: 0)
        screen.apply(r.frame(for: wide))
        screen.apply(r.frame(for: narrow))
        #expect(screen.text(0) == "ab  ")
    }

    @Test func resizeForcesFullRepaint() {
        var r = ScreenRenderer()
        _ = r.frame(for: buffer(["abc"]))
        let out = r.frame(for: buffer(["abcd", "efgh"]))
        #expect(out.contains("\u{1B}[2J"))
    }

    @Test func invalidateForcesFullRepaint() {
        var r = ScreenRenderer()
        let b = buffer(["abc"])
        _ = r.frame(for: b)
        r.invalidate()
        #expect(r.frame(for: b).contains("\u{1B}[2J"))
    }

    @Test func styleChangesAreEmittedAndResetAtFrameEnd() {
        var r = ScreenRenderer()
        var b = CellBuffer(columns: 6, rows: 1)
        b.write("ab", x: 0, y: 0, style: Style(inverse: true))
        b.write("cd", x: 2, y: 0)
        let out = r.frame(for: b)
        #expect(out.contains("\u{1B}[0;7m"))
        #expect(out.hasSuffix("cd") || out.hasSuffix("\u{1B}[0m"))
        // After an inverse span, the plain text that follows is preceded by a reset.
        #expect(out.contains("\u{1B}[0mcd"))
    }

    @Test func zeroSizedBufferProducesNoPaint() {
        var r = ScreenRenderer()
        let out = r.frame(for: CellBuffer(columns: 0, rows: 0))
        #expect(!out.contains("H"))
    }

    @Test func outputNeverContainsRawControlBytesFromContent() {
        // The renderer only ever emits ESC from its own sequences; sanitized text cannot add more.
        var r = ScreenRenderer()
        var b = CellBuffer(columns: 20, rows: 1)
        b.write(TextSanitizer.sanitize("a\u{1B}[31mb"), x: 0, y: 0)
        let out = r.frame(for: b)
        #expect(!out.contains("\u{1B}[31m")) // only the visible, defused text remains
    }
}

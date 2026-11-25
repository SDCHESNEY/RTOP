import Testing
@testable import TerminalUI

@Suite struct CellBufferTests {
    @Test func writesAndClipsAtTheRightEdge() {
        var b = CellBuffer(columns: 5, rows: 2)
        #expect(b.write("abcdefgh", x: 0, y: 0) == 5)
        #expect(b.rowText(0) == "abcde")
        #expect(b.write("xyz", x: 3, y: 1) == 2)
        #expect(b.rowText(1) == "   xy")
    }

    @Test func respectsMaxColumns() {
        var b = CellBuffer(columns: 10, rows: 1)
        b.write("abcdefgh", x: 2, y: 0, maxColumns: 3)
        #expect(b.rowText(0) == "  abc     ")
    }

    @Test func outOfRangeWritesAreIgnored() {
        var b = CellBuffer(columns: 3, rows: 1)
        #expect(b.write("a", x: 0, y: 5) == 0)
        #expect(b.write("a", x: 9, y: 0) == 0)
        #expect(b.write("a", x: 0, y: -1) == 0)
        #expect(b.rowText(0) == "   ")
    }

    @Test func wideCharacterOccupiesTwoCellsAndNeverHalfFits() {
        var b = CellBuffer(columns: 4, rows: 1)
        b.write("日本語", x: 0, y: 0)
        #expect(b.rowText(0) == "日本")
        #expect(b[0, 0].glyph == "日")
        #expect(b[1, 0].glyph == nil)

        var edge = CellBuffer(columns: 2, rows: 1)
        edge.write("a日", x: 0, y: 0) // the wide char would need a third column
        #expect(edge.rowText(0) == "a ")
    }

    @Test func overwritingHalfOfAWideCharacterBlanksTheOtherHalf() {
        var b = CellBuffer(columns: 4, rows: 1)
        b.write("日", x: 0, y: 0)
        b.write("x", x: 1, y: 0) // lands on the right half
        #expect(b.rowText(0) == " x  ") // the orphaned lead is blanked, not left half-drawn
        var c = CellBuffer(columns: 4, rows: 1)
        c.write("日", x: 0, y: 0)
        c.write("x", x: 0, y: 0) // lands on the lead
        #expect(c.rowText(0) == "x   ")
        #expect(c[1, 0].glyph == " ")
    }

    @Test func zeroSizedBufferIsSafe() {
        var b = CellBuffer(columns: 0, rows: 0)
        b.write("a", x: 0, y: 0)
        b.fillRow(0, style: .plain)
        #expect(b.rowText(0) == "")
    }

    @Test func fillRowAppliesStyle() {
        var b = CellBuffer(columns: 3, rows: 1)
        b.fillRow(0, style: Style(inverse: true))
        #expect(b[2, 0].style.inverse)
    }
}

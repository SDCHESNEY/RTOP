import MonitorCore
import Testing
@testable import TerminalUI

@Suite struct ProcessTableViewTests {
    private func lines(_ b: CellBuffer) -> [String] { (0..<b.rows).map { b.rowText($0) } }
    private func blank(_ width: Int) -> String { String(repeating: " ", count: width) }

    private static let overview80 = [
        "rtop  6 processes  up 1d 3h  load 1.50 2.25 3.00                                ",
        "CPU  [████░░░░░░░░░░░░░░░░░░░░░░░░░░░░]  12.5%                         ▂        ",
        "Core ▁▃▅█  unclassified · 12 logical · Performance 8 · Efficiency 4             ",
        "Mem  [██████████░░░░░░░░░░░░░] 7.0G/16.0G approx. used                         ▄",
        "     active 4.0G  inactive 3.0G  wired 2.0G  compressor 1.0G  free 512.0M       ",
        "     purgeable 100.0M  speculative 200.0M  file-backed 1.2G                     ",
        "Swap 0B/2.0G  pressure normal (last notified 10s ago)                           ",
    ]

    @Test func golden80x24() {
        let size = TerminalSize(columns: 80, rows: 24)
        let out = lines(ProcessTableView.render(ViewFixtures.state(size: size, selecting: 2), size: size))
        var expected = Self.overview80 + [
            "   PID▲ NAME                                  USER         CPU%     MEM STATE   ",
            "      1 launchd                               root          0.0   11.8M running ",
            "     98 logd                                  root          0.3    7.6M sleeping",
            "    412 Safari                                shawn        12.3  512.0M sleeping",
            "    777 kernel_task                           —               —       — ?       ",
            "   1234 Xcode                                 shawn       145.7    3.0G running ",
            "   2000 日本語アプリ                          shawn         1.0      4K stopped ",
        ]
        expected += Array(repeating: blank(80), count: 9)
        expected.append("q quit  ↑↓/jk move  s sort  r reverse  / filter  space pause  · 1 limited       ")
        #expect(out == expected)
    }

    @Test func golden120x40AddsColumnAndWidensHistories() {
        let size = TerminalSize(columns: 120, rows: 40)
        var state = ViewFixtures.state(size: size, selecting: 0)
        for n in 2...4 { _ = Reducer.reduce(&state, .snapshot(ViewFixtures.snapshot(sequence: UInt64(n)))) }
        let out = lines(ProcessTableView.render(state, size: size))
        #expect(out[0].hasPrefix("rtop  6 processes  up 1d 3h  load 1.50 2.25 3.00"))
        #expect(out[1].hasPrefix("CPU  [█████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░]  12.5%"))
        #expect(out[1].contains("▂▂▂▂")) // four samples of the same value
        #expect(out[7].hasPrefix("   PID▲    PPID NAME"))
        #expect(out[7].hasSuffix("USER         CPU%     MEM STATE   "))
        #expect(out[8].hasPrefix("      1       1 launchd"))
        #expect(out[8].hasSuffix("root          0.0   11.8M running "))
        #expect(out[13].hasPrefix("   2000       1 日本語アプリ"))
        #expect(out[14...38].allSatisfy { $0 == blank(120) })
        #expect(out[39].hasPrefix("q quit"))
    }

    @Test func golden40x8DropsLowPriorityColumns() {
        let size = TerminalSize(columns: 40, rows: 8)
        let out = lines(ProcessTableView.render(ViewFixtures.state(size: size, selecting: 0), size: size))
        #expect(out[1] == "   PID▲ NAME       CPU%     MEM STATE   ")
        #expect(out[5] == "    777 kernel_…      —       — ?       ")
        #expect(!out[1].contains("USER"))
    }

    @Test func columnPriorityWhenNarrowing() {
        func titles(_ width: Int) -> [String] { ProcessTableView.visibleColumns(width: width).map(\.title) }
        #expect(titles(120) == ["PID", "PPID", "NAME", "USER", "CPU%", "MEM", "STATE"])
        #expect(titles(99) == ["PID", "NAME", "USER", "CPU%", "MEM", "STATE"])
        #expect(titles(80) == ["PID", "NAME", "USER", "CPU%", "MEM", "STATE"])
        #expect(titles(60) == ["PID", "NAME", "USER", "CPU%", "MEM", "STATE"])
        #expect(titles(40) == ["PID", "NAME", "CPU%", "MEM", "STATE"])
        #expect(titles(31) == ["PID", "NAME", "CPU%", "MEM"])
        #expect(titles(30) == ["PID", "NAME", "CPU%"])
        #expect(titles(20) == ["PID", "NAME"])
        #expect(titles(10) == ["NAME"])
    }

    @Test func everyWidthRendersWithinBounds() {
        for columns in 1...130 {
            for rows in [1, 4, 5, 6, 24] {
                let size = TerminalSize(columns: columns, rows: rows)
                let b = ProcessTableView.render(ViewFixtures.state(size: size, selecting: 3), size: size)
                #expect(b.columns == columns && b.rows == rows)
                for y in 0..<rows { #expect(DisplayWidth.of(b.rowText(y)) <= columns) }
            }
        }
    }

    @Test func belowMinimumShowsResizeMessageWithoutCrashing() {
        for size in [TerminalSize(columns: 19, rows: 5), TerminalSize(columns: 20, rows: 4),
                     TerminalSize(columns: 1, rows: 1), TerminalSize(columns: 0, rows: 0),
                     TerminalSize(columns: 5, rows: 2)] {
            let b = ProcessTableView.render(ViewFixtures.state(size: size), size: size)
            if size.columns > 0, size.rows > 0 {
                #expect(b.rowText(0).hasPrefix(String("Resize".prefix(size.columns))))
            }
        }
    }

    @Test func onlyTheSelectedRowIsHighlighted() {
        let size = TerminalSize(columns: 80, rows: 24)
        let b = ProcessTableView.render(ViewFixtures.state(size: size, selecting: 2), size: size)
        for y in 0..<b.rows {
            let expected = (y == 10) // 7 overview rows, header, then rows 0,1,2 -> y == 10 is index 2
            #expect(b[0, y].style.inverse == expected, "row \(y)")
            #expect(b[79, y].style.inverse == expected, "row \(y) right edge")
        }
    }

    @Test func unavailableValuesRenderAsDashNeverZero() {
        let size = TerminalSize(columns: 80, rows: 24)
        let b = ProcessTableView.render(ViewFixtures.state(size: size), size: size)
        let row = b.rowText(11)
        #expect(row.contains("kernel_task"))
        #expect(row.filter { $0 == "—" }.count == 3) // user, cpu, memory
        #expect(!row.contains("0.0"))
    }

    @Test func hostileNamesAreSanitizedBeforeDisplay() {
        let size = TerminalSize(columns: 80, rows: 24)
        let rows = [ViewFixtures.row(5, "bad\u{1B}[2Jname\u{07}\nline", user: "us\u{1B}er")]
        let b = ProcessTableView.render(ViewFixtures.state(size: size, rows: rows), size: size)
        for y in 0..<b.rows {
            for x in 0..<b.columns {
                if let g = b[x, y].glyph {
                    #expect(!g.unicodeScalars.contains { TextSanitizer.isUnsafe($0) }, "cell \(x),\(y)")
                }
            }
        }
        #expect(b.rowText(8).contains("bad?[2Jname??line"))
    }

    @Test func overlongNameIsTruncatedWithEllipsis() {
        let size = TerminalSize(columns: 30, rows: 6)
        let rows = [ViewFixtures.row(5, String(repeating: "n", count: 200))]
        let b = ProcessTableView.render(ViewFixtures.state(size: size, rows: rows), size: size)
        #expect(b.rowText(2).contains("…"))
        #expect(DisplayWidth.of(b.rowText(2)) == 30)
    }

    @Test func scrollWindowShowsRowsFromOffset() {
        let size = TerminalSize(columns: 40, rows: 8) // 5 visible rows
        let rows = (1...100).map { ViewFixtures.row(Int32($0), "p\($0)", cpu: 0, rss: 1024) }
        var state = ViewFixtures.state(size: size, rows: rows, selecting: nil)
        _ = Reducer.reduce(&state, .key(.end))
        let b = ProcessTableView.render(state, size: size)
        #expect(b.rowText(2).contains("p96"))
        #expect(b.rowText(6).contains("p100"))
        #expect(b[0, 6].style.inverse)
    }

    @Test func statesBeforeAndWithoutData() {
        let size = TerminalSize(columns: 40, rows: 8)
        let waiting = ProcessTableView.render(AppState(terminalSize: size), size: size)
        #expect(waiting.rowText(0).contains("collecting"))
        #expect(waiting.rowText(2).hasPrefix("Collecting"))

        let empty = ProcessTableView.render(ViewFixtures.state(size: size, rows: []), size: size)
        #expect(empty.rowText(2).hasPrefix("No processes."))
    }

    @Test func refreshFailureShowsInFooterSanitized() {
        let size = TerminalSize(columns: 60, rows: 8)
        var state = ViewFixtures.state(size: size)
        _ = Reducer.reduce(&state, .collectionFailed(sequence: 9, message: "boom\u{1B}[31m"))
        let footer = ProcessTableView.render(state, size: size).rowText(7)
        #expect(footer.hasPrefix("refresh failed: boom?[31m"))
    }

    @Test func byteFormatting() {
        #expect(ByteFormat.short(0) == "0B")
        #expect(ByteFormat.short(1023) == "1023B")
        #expect(ByteFormat.short(2048) == "2K")
        #expect(ByteFormat.short(5 * 1024 * 1024) == "5.0M")
        #expect(ByteFormat.short(3 * 1024 * 1024 * 1024) == "3.0G")
        #expect(ByteFormat.short(UInt64.max).hasSuffix("T"))
    }
}

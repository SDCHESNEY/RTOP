import Foundation
import MonitorCore
import Testing
@testable import TerminalUI

@Suite struct OverviewViewTests {
    private let size = TerminalSize(columns: 80, rows: 24)
    private func lines(_ b: CellBuffer) -> [String] { (0..<b.rows).map { b.rowText($0) } }

    private func render(_ state: AppState, _ options: RenderOptions = RenderOptions()) -> CellBuffer {
        ProcessTableView.render(state, size: state.terminalSize, options: options)
    }

    @Test func color256AddsForegroundToBarsWithSameText() {
        let state = ViewFixtures.state(size: size)
        let mono = render(state)
        let color = render(state, RenderOptions(color: .palette256))
        #expect(lines(mono) == lines(color))
        #expect(mono[6, 1].style.foreground == nil)
        #expect(color[6, 1].style.foreground == 34) // 12.5% load: green
        #expect(color[6, 3].style.foreground == 34)
        #expect((0..<80).allSatisfy { mono[$0, 1].style.foreground == nil })
    }

    @Test func highLoadTurnsTheBarRed() {
        var state = makeState(cpu: 95)
        _ = Reducer.reduce(&state, .tick)
        #expect(render(state, RenderOptions(color: .palette256))[6, 1].style.foreground == 160)
    }

    private func makeState(cpu: Double) -> AppState {
        var state = AppState(terminalSize: size)
        let snapshot = ViewFixtures.snapshot(
            sequence: 1, cpu: .value(CPUReading(aggregatePercent: cpu, perCorePercent: [cpu])))
        _ = Reducer.reduce(&state, .snapshot(snapshot))
        return state
    }

    @Test func asciiFallbackUsesNoNonASCIIInBarsOrSparklines() {
        let state = ViewFixtures.state(size: size)
        let out = lines(render(state, RenderOptions(asciiGlyphs: true)))
        #expect(out[1].hasPrefix("CPU  [####----"))
        #expect(!out[1].contains("█") && !out[1].contains("░") && !out[1].contains("▂"))
        #expect(!out[2].prefix(9).contains { !$0.isASCII })
        #expect(out[7].contains("PID^"))
    }

    @Test func detectionFromEnvironment() {
        let utf8: [String: String] = ["TERM": "xterm-256color", "LANG": "en_US.UTF-8"]
        #expect(RenderOptions.detect(environment: utf8) == RenderOptions(color: .palette256, asciiGlyphs: false))
        #expect(RenderOptions.detect(environment: utf8.merging(["NO_COLOR": "1"]) { $1 }).color == .mono)
        #expect(RenderOptions.detect(environment: utf8.merging(["NO_COLOR": ""]) { $1 }).color == .palette256)
        #expect(RenderOptions.detect(environment: ["TERM": "dumb", "LANG": "en_US.UTF-8"]).color == .mono)
        #expect(RenderOptions.detect(environment: ["LANG": "en_US.UTF-8"]).color == .mono)
        #expect(RenderOptions.detect(environment: ["TERM": "xterm", "LANG": "C"]).asciiGlyphs)
        #expect(RenderOptions.detect(environment: ["TERM": "xterm"]).asciiGlyphs)
        #expect(!RenderOptions.detect(environment: ["TERM": "xterm", "LC_ALL": "en_US.UTF-8", "LANG": "C"]).asciiGlyphs)
    }

    @Test func pressureIsUnknownUntilNotified() {
        var state = AppState(terminalSize: size)
        _ = Reducer.reduce(&state, .snapshot(ViewFixtures.snapshot(sequence: 1, pressure: .unknown)))
        #expect(render(state).rowText(6).contains("pressure unknown (no notification yet)"))
    }

    @Test func pressureShowsLastStateWithAgeAndColor() {
        var state = AppState(terminalSize: size)
        let p = MemoryPressureReading(state: .critical, observedAtNanoseconds: 10_000_000_000)
        _ = Reducer.reduce(&state, .snapshot(ViewFixtures.snapshot(sequence: 1, capturedAt: 75_000_000_000, pressure: p)))
        let b = render(state, RenderOptions(color: .palette256))
        #expect(b.rowText(6).contains("critical (last notified 1m ago)"))
        let x = b.rowText(6).distance(from: b.rowText(6).startIndex, to: b.rowText(6).range(of: "critical")!.lowerBound)
        #expect(b[x, 6].style.foreground == 160)
    }

    @Test func unavailableCPUAndMemoryShowReasonsNotZero() {
        var state = AppState(terminalSize: size)
        let snapshot = ViewFixtures.snapshot(
            sequence: 1, cpu: .unavailable(.notYetSampled), memory: .unavailable(.permissionDenied))
        _ = Reducer.reduce(&state, .snapshot(snapshot))
        let b = render(state)
        #expect(b.rowText(1).hasPrefix("CPU  — not yet sampled"))
        #expect(b.rowText(2).contains("—"))
        #expect(b.rowText(3).hasPrefix("Mem  — permission denied"))
        #expect(b.rowText(4).trimmingCharacters(in: .whitespaces).isEmpty)
    }

    @Test func missingCategoryRendersDashAndMissingComponentHidesApproxUsed() {
        var memory = ViewFixtures.memory
        memory.wiredPages = nil
        var state = AppState(terminalSize: size)
        _ = Reducer.reduce(&state, .snapshot(ViewFixtures.snapshot(sequence: 1, memory: .value(memory))))
        let b = render(state)
        #expect(b.rowText(3).contains("approx. used unavailable"))
        #expect(b.rowText(4).contains("wired —"))
    }

    @Test func topologyIsCountsOnlyAndUnclassified() {
        let b = render(ViewFixtures.state(size: size))
        let row = b.rowText(2)
        #expect(row.contains("unclassified"))
        #expect(row.contains("Performance 8") && row.contains("Efficiency 4"))
        #expect(OverviewView.topologyText(.unavailable(.unsupported)) == "unclassified cores")
        #expect(OverviewView.topologyText(.value(CoreTopology(logicalCPUs: 8, physicalCPUs: 8))) == "unclassified · 8 logical")
    }

    @Test func hostileTopologyNamesAreSanitized() {
        let t = CoreTopology(logicalCPUs: 4, physicalCPUs: 4, levels: [.init(index: 0, name: "P\u{1B}[2J", logicalCPUs: 4)])
        #expect(!OverviewView.topologyText(.value(t)).contains("\u{1B}"))
    }

    @Test func sparklineShowsGapsForUnavailableSamples() {
        var state = AppState(terminalSize: size)
        for n in 1...3 {
            let cpu: Availability<CPUReading> = n == 2 ? .unavailable(.notYetSampled)
                : .value(CPUReading(aggregatePercent: 100, perCorePercent: [100]))
            _ = Reducer.reduce(&state, .snapshot(ViewFixtures.snapshot(sequence: UInt64(n), cpu: cpu)))
        }
        #expect(render(state).rowText(1).contains("█·█"))
        #expect(render(state, RenderOptions(asciiGlyphs: true)).rowText(1).contains("#?#"))
    }

    @Test func pausedAndStaleFlagsShowInTheTitle() {
        var state = ViewFixtures.state(size: size)
        _ = Reducer.reduce(&state, .key(.character(" ")))
        #expect(render(state).rowText(0).hasSuffix("PAUSED"))
        for _ in 0..<AppState.staleAfterTicks { _ = Reducer.reduce(&state, .tick) }
        #expect(render(state).rowText(0).hasSuffix("PAUSED STALE"))
        let small = TerminalSize(columns: 40, rows: 8)
        var s2 = ViewFixtures.state(size: small)
        _ = Reducer.reduce(&s2, .key(.character(" ")))
        #expect(render(s2).rowText(0).hasSuffix("PAUSED"))
    }

    @Test func filteredCountAndNoMatchState() {
        var state = ViewFixtures.state(size: size)
        _ = Reducer.reduce(&state, .key(.character("/")))
        for ch in "safari" { _ = Reducer.reduce(&state, .key(.character(ch))) }
        var b = render(state)
        #expect(b.rowText(0).contains("1 of 6 processes"))
        #expect(b.rowText(23).hasPrefix("/safari_"))

        for ch in "zz" { _ = Reducer.reduce(&state, .key(.character(ch))) }
        b = render(state)
        #expect(b.rowText(8).hasPrefix("No matching processes."))
    }

    @Test func footerShowsEditorErrorAndCommittedFilter() {
        var state = ViewFixtures.state(size: size)
        for key: KeyEvent in [.character("/"), .character("p"), .character("i"), .character("d"), .character(":")] {
            _ = Reducer.reduce(&state, .key(key))
        }
        #expect(render(state).rowText(23).contains("! pid: needs a value"))
        _ = Reducer.reduce(&state, .key(.escape))
        for key: KeyEvent in [.character("/"), .character("x"), .enter] { _ = Reducer.reduce(&state, .key(key)) }
        #expect(render(state).rowText(23).hasPrefix("filter: x  q quit"))
    }

    @Test func sortIndicatorFollowsKeyAndDirection() {
        var state = ViewFixtures.state(size: size)
        _ = Reducer.reduce(&state, .key(.character("s")))
        _ = Reducer.reduce(&state, .key(.character("r")))
        let header = render(state).rowText(7)
        #expect(header.contains("NAME▼") && !header.contains("PID▲"))
    }

    @Test func durationFormatting() {
        #expect(OverviewView.durationText(-5) == "0s")
        #expect(OverviewView.durationText(42) == "42s")
        #expect(OverviewView.durationText(125) == "2m")
        #expect(OverviewView.durationText(3 * 3600 + 5 * 60) == "3h 05m")
        #expect(OverviewView.durationText(3 * 86_400 + 4 * 3600) == "3d 4h")
    }

    @Test func everySizeAndModeStaysInBounds() {
        for columns in [1, 19, 20, 59, 60, 79, 80, 99, 100, 120, 200] {
            for rows in [1, 5, 19, 20, 24, 40] {
                let s = TerminalSize(columns: columns, rows: rows)
                var state = ViewFixtures.state(size: s)
                _ = Reducer.reduce(&state, .key(.character(" ")))
                for options in [RenderOptions(), RenderOptions(color: .palette256, asciiGlyphs: true)] {
                    let b = ProcessTableView.render(state, size: s, options: options)
                    for y in 0..<rows { #expect(DisplayWidth.of(b.rowText(y)) <= columns) }
                }
            }
        }
    }
}

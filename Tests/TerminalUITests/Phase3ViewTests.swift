import Foundation
import MonitorCore
import Testing
@testable import TerminalUI

@Suite struct Phase3ViewTests {
    private let size = TerminalSize(columns: 80, rows: 24)
    private func lines(_ b: CellBuffer) -> [String] { (0..<b.rows).map { b.rowText($0) } }
    private func render(_ state: AppState, _ options: RenderOptions = RenderOptions()) -> [String] {
        lines(ProcessTableView.render(state, size: state.terminalSize, options: options))
    }

    private func press(_ state: inout AppState, _ keys: KeyEvent...) {
        for key in keys { _ = Reducer.reduce(&state, .key(key)) }
    }

    private func detailState(selecting index: Int = 2) -> AppState {
        var state = ViewFixtures.state(size: size, selecting: index)
        press(&state, .character("d"))
        let pane = state.detailPane!
        let args = Availability<ProcessDetails.CommandLine>.value(
            .init(arguments: ["/x/Safari", "--url", "https://example.com/\u{1B}[31mred"], truncated: false))
        _ = Reducer.reduce(&state, .detailsLoaded(
            generation: pane.generation,
            details: ProcessDetails(identity: pane.identity, commandLine: args, threadCount: .value(42), virtualBytes: .value(1 << 30))))
        return state
    }

    // MARK: Details

    @Test func detailPaneShowsFieldsAndReplacesTheTable() {
        let out = render(detailState())
        #expect(out[7].hasPrefix("DETAILS  pid 412  Safari"))
        let text = out.joined(separator: "\n")
        #expect(text.contains("Parent    1 (launchd)"))
        #expect(text.contains("User      shawn (uid 501)"))
        #expect(text.contains("Threads   42"))
        #expect(text.contains("Virtual   1.0G"))
        #expect(text.contains("Path      /x/Safari"))
        #expect(text.contains("Started   1970-01-01T00:00:01Z"))
        #expect(!text.contains("kernel_task")) // the table is replaced
        #expect(out[23].hasPrefix("Esc close  ↑↓ select  x signal"))
    }

    @Test func commandLineIsSanitizedAndWrapped() {
        let out = render(detailState()).joined(separator: "\n")
        #expect(!out.contains("\u{1B}"))
        #expect(out.contains("Command   /x/Safari --url https://example.com/?[31mred"))
    }

    @Test func loadingAndUnavailableStatesAreExplicit() {
        var state = ViewFixtures.state(size: size, selecting: 2)
        press(&state, .character("d"))
        #expect(render(state).joined(separator: "\n").contains("Loading…"))
        let pane = state.detailPane!
        _ = Reducer.reduce(&state, .detailsLoaded(generation: pane.generation, details: .unavailable(pane.identity, .permissionDenied)))
        let text = render(state).joined(separator: "\n")
        #expect(text.contains("Command   — (permission denied)"))
        #expect(text.contains("Threads   — (permission denied)"))
        #expect(!text.contains("Threads   0"))
    }

    @Test func longCommandLinesAreBoundedToTheAvailableRows() {
        var state = detailState()
        let pane = state.detailPane!
        let huge = String(repeating: "word ", count: 2000)
        _ = Reducer.reduce(&state, .detailsLoaded(
            generation: pane.generation,
            details: ProcessDetails(identity: pane.identity, commandLine: .value(.init(arguments: [huge], truncated: true)))))
        let out = render(state)
        #expect(out.count == 24)
        #expect(out[23].hasPrefix("Esc close"))
    }

    // MARK: Tree

    @Test func treeModeIndentsChildrenAndMarksUnattached() {
        var rows = ViewFixtures.rows
        rows[2].parentPID = .value(98)      // Safari under logd
        rows[3].parentPID = .value(55_555)  // kernel_task: missing parent
        var state = AppState(terminalSize: size)
        _ = Reducer.reduce(&state, .snapshot(ViewFixtures.snapshot(sequence: 1, rows: rows)))
        press(&state, .character("t"))
        let out = render(state)
        let table = out[8...16].joined(separator: "\n")
        #expect(out[8].contains(" launchd"))
        #expect(table.contains("└ logd") || table.contains("logd"))
        #expect(out.contains { $0.contains("└ Safari") })
        #expect(out.contains { $0.contains("Unattached") })
        #expect(out.contains { $0.contains("└ kernel_task") })
    }

    @Test func treeContextRowsAreDimmedAndMatchesAreNot() {
        var rows = ViewFixtures.rows
        rows[2].parentPID = .value(98)
        var state = AppState(terminalSize: size)
        _ = Reducer.reduce(&state, .snapshot(ViewFixtures.snapshot(sequence: 1, rows: rows)))
        press(&state, .character("t"), .character("/"))
        for ch in "safari" { press(&state, .character(ch)) }
        let buffer = ProcessTableView.render(state, size: size)
        let ancestors = (8..<12).filter { buffer.rowText($0).contains("logd") || buffer.rowText($0).contains("launchd") }
        #expect(ancestors.count == 2)
        for y in ancestors { #expect(buffer[10, y].style.dim) }
        let match = (8..<12).first { buffer.rowText($0).contains("Safari") }!
        #expect(!buffer[10, match].style.dim)
    }

    @Test func asciiTreeUsesNoNonASCIIBranch() {
        var rows = ViewFixtures.rows
        rows[2].parentPID = .value(98)
        var state = AppState(terminalSize: size)
        _ = Reducer.reduce(&state, .snapshot(ViewFixtures.snapshot(sequence: 1, rows: rows)))
        press(&state, .character("t"))
        let out = render(state, RenderOptions(asciiGlyphs: true))
        #expect(out.contains { $0.contains("`- Safari") })
    }

    // MARK: Modal and help

    @Test func signalDialogShowsTargetSignalExplanationAndStage() {
        var state = ViewFixtures.state(size: size, selecting: 2)
        press(&state, .character("x"))
        let text = render(state).joined(separator: "\n")
        #expect(text.contains("Send signal"))
        #expect(text.contains("Safari  (pid 412)"))
        #expect(text.contains("uid 501  /x/Safari"))
        #expect(text.contains("[SIGTERM]"))
        #expect(text.contains("Asks the process to terminate."))
        #expect(text.contains("Enter or y sends SIGTERM."))
    }

    @Test func destructiveSignalIsLabelledAndChooserTracksSelection() {
        var state = ViewFixtures.state(size: size, selecting: 2)
        press(&state, .character("x"), .right)
        let text = render(state).joined(separator: "\n")
        #expect(text.contains("[SIGKILL]"))
        #expect(text.contains("Destructive"))
        #expect(!text.contains("[SIGTERM]"))
    }

    @Test func protectedTargetShowsBothStages() {
        var state = ViewFixtures.state(size: size, selecting: 1) // logd (PID 1 would be refused)
        press(&state, .character("x"))
        // The fixture's uid is 501 for everyone; make the target root-owned.
        state.signalWorkflow?.request.uid = 0
        state.signalWorkflow?.request.isProtected = true
        #expect(render(state).joined(separator: "\n").contains("Protected target"))
        press(&state, .enter)
        let second = render(state).joined(separator: "\n")
        #expect(second.contains("PROTECTED: really send SIGTERM to logd?"))
        #expect(second.contains("Enter does not confirm"))
    }

    @Test func dialogSanitizesHostileNames() {
        var rows = ViewFixtures.rows
        rows[2].name = "evil\u{1B}[2Jname"
        var state = AppState(terminalSize: size)
        _ = Reducer.reduce(&state, .snapshot(ViewFixtures.snapshot(sequence: 1, rows: rows)))
        press(&state, .down, .down, .character("x"))
        #expect(!render(state).joined().contains("\u{1B}"))
    }

    @Test func resultMessageReplacesTheFooterHint() {
        var state = ViewFixtures.state(size: size, selecting: 2)
        press(&state, .character("x"), .enter)
        let request = state.signalWorkflow!.request
        _ = Reducer.reduce(&state, .signalResult(request: request, result: .success(SignalSent(pid: 412, signal: .term))))
        #expect(render(state)[23].hasPrefix("Signal sent: SIGTERM to pid 412 (Safari)."))
    }

    @Test func helpOverlayListsBindingsFromTheTable() {
        var state = ViewFixtures.state(size: TerminalSize(columns: 100, rows: 40), selecting: 0)
        press(&state, .character("?"))
        let text = render(state).joined(separator: "\n")
        #expect(text.contains("Help"))
        #expect(text.contains("Toggle process tree"))
        #expect(text.contains("Send a signal (asks first)"))
        #expect(text.contains("Left/Right"))
    }

    @Test func overlaysNeverCrashOrOverflowAtAnySize() {
        for columns in [1, 5, 6, 20, 21, 40, 80, 130] {
            for rows in [1, 2, 3, 5, 8, 24, 50] {
                let s = TerminalSize(columns: columns, rows: rows)
                var state = ViewFixtures.state(size: s, selecting: 2)
                for setup in 0..<5 {
                    var st = state
                    switch setup {
                    case 0: press(&st, .character("?"))
                    case 1: press(&st, .character("x"))
                    case 2: press(&st, .character("d"))
                    case 3: press(&st, .character("t"))
                    default: press(&st, .character("t"), .character("d"), .character("x"), .character("?"))
                    }
                    let b = ProcessTableView.render(st, size: s)
                    #expect(b.columns == max(0, columns) && b.rows == max(0, rows))
                }
                state = AppState(terminalSize: s)
            }
        }
    }
}

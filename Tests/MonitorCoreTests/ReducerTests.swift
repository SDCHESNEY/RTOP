import Testing
@testable import MonitorCore

@Suite struct ReducerTests {
    private func makeState(rows: Int = 24) -> AppState {
        AppState(terminalSize: TerminalSize(columns: 80, rows: rows))
    }

    private func load(_ state: inout AppState, sequence: UInt64, pids: [Int32]) {
        _ = Reducer.reduce(&state, .snapshot(Fixtures.snapshot(sequence, pids.map { Fixtures.process($0) })))
    }

    @Test func tickRequestsARefresh() {
        var state = makeState()
        #expect(Reducer.reduce(&state, .tick) == [.requestRefresh])
    }

    @Test func quitKeysAndTerminationExit() {
        for key: KeyEvent in [.character("q"), .ctrl("c"), .escape] {
            var state = makeState()
            #expect(Reducer.reduce(&state, .key(key)) == [.exit])
        }
        var state = makeState()
        #expect(Reducer.reduce(&state, .terminate) == [.exit])
    }

    @Test func kIsNavigationNeverTermination() {
        var state = makeState()
        load(&state, sequence: 1, pids: [1, 2, 3])
        _ = Reducer.reduce(&state, .key(.down))
        #expect(Reducer.reduce(&state, .key(.character("k"))) == [])
        #expect(state.selection == Fixtures.identity(1))
    }

    @Test func firstSnapshotSelectsFirstRowAndSortsByPID() {
        var state = makeState()
        load(&state, sequence: 1, pids: [30, 10, 20])
        #expect(state.rows.map(\.identity.pid) == [10, 20, 30])
        #expect(state.selection == Fixtures.identity(10))
    }

    @Test func navigationIsBounded() {
        var state = makeState()
        load(&state, sequence: 1, pids: [1, 2, 3])
        _ = Reducer.reduce(&state, .key(.up))
        #expect(state.selectedIndex == 0)
        for _ in 0..<10 { _ = Reducer.reduce(&state, .key(.down)) }
        #expect(state.selectedIndex == 2)
        _ = Reducer.reduce(&state, .key(.home))
        #expect(state.selectedIndex == 0)
        _ = Reducer.reduce(&state, .key(.end))
        #expect(state.selectedIndex == 2)
    }

    @Test func navigationWithNoRowsDoesNothing() {
        var state = makeState()
        for key: KeyEvent in [.up, .down, .pageDown, .pageUp, .home, .end] {
            #expect(Reducer.reduce(&state, .key(key)) == [])
        }
        #expect(state.selection == nil)
    }

    @Test func pagingMovesByAVisiblePageAndKeepsSelectionVisible() {
        var state = makeState(rows: 13) // 10 visible rows
        load(&state, sequence: 1, pids: Array(1...100))
        _ = Reducer.reduce(&state, .key(.pageDown))
        #expect(state.selectedIndex == 10)
        #expect(state.scrollOffset == 1) // selected row 10 is the last visible row of a 10-row window
        _ = Reducer.reduce(&state, .key(.end))
        #expect(state.selectedIndex == 99)
        #expect(state.scrollOffset == 90)
        _ = Reducer.reduce(&state, .key(.home))
        #expect(state.scrollOffset == 0)
    }

    @Test func selectionSurvivesReorderAndInsertion() {
        var state = makeState()
        load(&state, sequence: 1, pids: [1, 2, 3])
        _ = Reducer.reduce(&state, .key(.down))
        #expect(state.selection == Fixtures.identity(2))
        load(&state, sequence: 2, pids: [0 + 9, 8, 3, 2, 1]) // new rows sort before and after
        #expect(state.selection == Fixtures.identity(2))
        #expect(state.selectedIndex == 1)
    }

    @Test func lostSelectionMovesToNextSurvivor() {
        var state = makeState()
        load(&state, sequence: 1, pids: [1, 2, 3, 4])
        _ = Reducer.reduce(&state, .key(.down))
        load(&state, sequence: 2, pids: [1, 3, 4]) // 2 exited
        #expect(state.selection == Fixtures.identity(3))
    }

    @Test func lostSelectionAtTheEndMovesToPreviousSurvivor() {
        var state = makeState()
        load(&state, sequence: 1, pids: [1, 2, 3])
        _ = Reducer.reduce(&state, .key(.end))
        load(&state, sequence: 2, pids: [1, 2])
        #expect(state.selection == Fixtures.identity(2))
    }

    @Test func lostSelectionWithAllRowsGoneClearsIt() {
        var state = makeState()
        load(&state, sequence: 1, pids: [1, 2])
        load(&state, sequence: 2, pids: [])
        #expect(state.selection == nil)
        load(&state, sequence: 3, pids: [5])
        #expect(state.selection == Fixtures.identity(5))
    }

    @Test func reusedPIDWithNewStartIsNotTheSelectedProcess() {
        var state = makeState()
        _ = Reducer.reduce(&state, .snapshot(Fixtures.snapshot(1, [Fixtures.process(1), Fixtures.process(7, start: 100)])))
        _ = Reducer.reduce(&state, .key(.down))
        #expect(state.selection == Fixtures.identity(7, start: 100))
        _ = Reducer.reduce(&state, .snapshot(Fixtures.snapshot(2, [Fixtures.process(1), Fixtures.process(7, start: 200)])))
        #expect(state.selection != Fixtures.identity(7, start: 200))
        #expect(state.selection == Fixtures.identity(1)) // nearest survivor, not the reused PID
    }

    @Test func staleAndDuplicateSnapshotsAreRejected() {
        var state = makeState()
        load(&state, sequence: 5, pids: [1, 2, 3])
        load(&state, sequence: 4, pids: [9])
        load(&state, sequence: 5, pids: [9])
        #expect(state.rows.map(\.identity.pid) == [1, 2, 3])
        #expect(state.lastAcceptedSequence == 5)
    }

    @Test func resizeKeepsSelectionVisible() {
        var state = makeState(rows: 30)
        load(&state, sequence: 1, pids: Array(1...50))
        _ = Reducer.reduce(&state, .key(.end))
        _ = Reducer.reduce(&state, .resize(TerminalSize(columns: 20, rows: 5)))
        let visible = ProcessTableLayout.visibleRows(for: state.terminalSize)
        #expect(visible == 2)
        let index = state.selectedIndex ?? -1
        #expect(index >= state.scrollOffset && index < state.scrollOffset + visible)
    }

    @Test func tinyOrZeroSizedTerminalsDoNotCrash() {
        var state = makeState()
        load(&state, sequence: 1, pids: [1, 2, 3])
        for size in [TerminalSize(columns: 0, rows: 0), TerminalSize(columns: 1, rows: 1), TerminalSize(columns: 20, rows: 5)] {
            _ = Reducer.reduce(&state, .resize(size))
            _ = Reducer.reduce(&state, .key(.pageDown))
            _ = Reducer.reduce(&state, .key(.end))
        }
        #expect(state.scrollOffset >= 0)
    }

    @Test func failuresAreBoundedAndClearedBySuccess() {
        var state = makeState()
        for i in 1...20 { _ = Reducer.reduce(&state, .collectionFailed(sequence: UInt64(i), message: "boom \(i)")) }
        #expect(state.messages.count <= AppState.maxMessages)
        #expect(state.messages.last?.text == "boom 20")
        load(&state, sequence: 30, pids: [1])
        #expect(state.messages.isEmpty)
    }

    @Test func staleFailureIsIgnored() {
        var state = makeState()
        load(&state, sequence: 10, pids: [1])
        _ = Reducer.reduce(&state, .collectionFailed(sequence: 3, message: "old"))
        #expect(state.messages.isEmpty)
    }
}

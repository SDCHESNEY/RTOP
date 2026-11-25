import Testing
@testable import MonitorCore

@Suite struct ReducerPhase2Tests {
    private func makeState(rows: Int = 24, history: Int = 60) -> AppState {
        AppState(terminalSize: TerminalSize(columns: 80, rows: rows), historyCapacity: history)
    }

    private func load(
        _ state: inout AppState, sequence: UInt64, _ processes: [ProcessSummary], cpu: Double? = nil,
        capturedAt: UInt64 = 0
    ) {
        var snapshot = Fixtures.snapshot(sequence, processes)
        snapshot.capturedAtNanoseconds = capturedAt
        if let cpu { snapshot.cpu = .value(CPUReading(aggregatePercent: cpu, perCorePercent: [cpu])) }
        _ = Reducer.reduce(&state, .snapshot(snapshot))
    }

    private func press(_ state: inout AppState, _ keys: KeyEvent...) {
        for key in keys { _ = Reducer.reduce(&state, .key(key)) }
    }

    private func type(_ state: inout AppState, _ text: String) {
        for ch in text { _ = Reducer.reduce(&state, .key(.character(ch))) }
    }

    private var sample: [ProcessSummary] {
        [
            Fixtures.process(1, name: "launchd", cpu: 1, resident: 300, user: "root", uid: 0),
            Fixtures.process(2, name: "Safari", cpu: 50, resident: 100, user: "shawn"),
            Fixtures.process(3, name: "bash", cpu: 20, resident: 200, user: "shawn"),
        ]
    }

    // MARK: Sorting

    @Test func sCyclesSortKeyAndRReverses() {
        var state = makeState()
        load(&state, sequence: 1, sample)
        #expect(state.sortKey == .pid && !state.sortDescending)
        press(&state, .character("s"))
        #expect(state.sortKey == .name)
        #expect(state.rows.map(\.name) == ["bash", "launchd", "Safari"])
        press(&state, .character("r"))
        #expect(state.sortDescending)
        #expect(state.rows.map(\.name) == ["Safari", "launchd", "bash"])
        for _ in 0..<5 { press(&state, .character("s")) }
        #expect(state.sortKey == .pid) // six presses in total: wrapped around
    }

    @Test func selectionFollowsIdentityAcrossSort() {
        var state = makeState()
        load(&state, sequence: 1, sample)
        press(&state, .down) // Safari (pid 2)
        let selected = state.selection
        press(&state, .character("s"), .character("s"), .character("s")) // pid -> name -> user -> cpu
        #expect(state.sortKey == .cpu)
        press(&state, .character("r"))
        #expect(state.selection == selected)
        #expect(state.rows[state.selectedIndex ?? -1].name == "Safari")
    }

    @Test func newSnapshotsKeepTheChosenOrder() {
        var state = makeState()
        load(&state, sequence: 1, sample)
        press(&state, .character("s"), .character("s"), .character("s"), .character("r")) // cpu descending
        load(&state, sequence: 2, sample + [Fixtures.process(9, name: "hot", cpu: 99)])
        #expect(state.rows.map(\.name) == ["hot", "Safari", "bash", "launchd"])
    }

    // MARK: Filtering

    @Test func slashOpensEditorAndTypingFiltersLive() {
        var state = makeState()
        load(&state, sequence: 1, sample)
        press(&state, .character("/"))
        #expect(state.filterEditor != nil)
        type(&state, "saf")
        #expect(state.rows.map(\.name) == ["Safari"])
        #expect(state.filterText == "saf")
        press(&state, .enter)
        #expect(state.filterEditor == nil)
        #expect(state.rows.map(\.name) == ["Safari"])
    }

    @Test func lettersAreTextWhileEditingNotCommands() {
        var state = makeState()
        load(&state, sequence: 1, sample)
        press(&state, .character("/"))
        for key: KeyEvent in [.character("q"), .character("k"), .character("s"), .character("r"), .character(" ")] {
            #expect(Reducer.reduce(&state, .key(key)) == [])
        }
        #expect(state.filterEditor?.text == "qksr ")
        #expect(state.sortKey == .pid && !state.sortDescending && !state.isPaused)
    }

    @Test func ctrlCStillQuitsWhileEditing() {
        var state = makeState()
        press(&state, .character("/"))
        #expect(Reducer.reduce(&state, .key(.ctrl("c"))) == [.exit])
    }

    @Test func escapeRestoresThePreviousFilter() {
        var state = makeState()
        load(&state, sequence: 1, sample)
        press(&state, .character("/"))
        type(&state, "bash")
        press(&state, .enter)
        press(&state, .character("/"))
        press(&state, .ctrl("u"))
        type(&state, "launch")
        #expect(state.rows.map(\.name) == ["launchd"])
        #expect(Reducer.reduce(&state, .key(.escape)) == [])
        #expect(state.filterEditor == nil)
        #expect(state.filterText == "bash")
        #expect(state.rows.map(\.name) == ["bash"])
    }

    @Test func escapeQuitsAgainOnceEditingEnds() {
        var state = makeState()
        press(&state, .character("/"), .escape)
        #expect(Reducer.reduce(&state, .key(.escape)) == [.exit])
    }

    @Test func invalidPredicateShowsErrorAndKeepsLastValidFilter() {
        var state = makeState()
        load(&state, sequence: 1, sample)
        press(&state, .character("/"))
        type(&state, "pid:1")
        #expect(state.rows.map(\.name) == ["launchd"])
        type(&state, "x") // "pid:1x" is not a valid PID
        #expect(state.filterEditor?.error != nil)
        #expect(state.filterText == "pid:1") // last valid filter still active
        #expect(state.rows.map(\.name) == ["launchd"])

        press(&state, .enter) // invalid text does not commit
        #expect(state.filterEditor != nil)

        press(&state, .backspace)
        #expect(state.filterEditor?.error == nil)
        press(&state, .enter)
        #expect(state.filterEditor == nil)
        #expect(state.filterText == "pid:1")
    }

    @Test func deletingAllTextClearsTheFilter() {
        var state = makeState()
        load(&state, sequence: 1, sample)
        press(&state, .character("/"))
        type(&state, "ba")
        press(&state, .backspace, .backspace)
        #expect(state.filter.isEmpty)
        #expect(state.rows.count == 3)
        press(&state, .backspace) // already empty: no crash
        press(&state, .enter)
        #expect(state.filterEditor == nil && state.filterText.isEmpty)
    }

    @Test func ctrlUClearsTheBuffer() {
        var state = makeState()
        load(&state, sequence: 1, sample)
        press(&state, .character("/"))
        type(&state, "bash")
        press(&state, .ctrl("u"))
        #expect(state.filterEditor?.text == "" && state.rows.count == 3)
    }

    @Test func controlCharactersAndOverlongTextAreNotAccepted() {
        var state = makeState()
        press(&state, .character("/"))
        _ = Reducer.reduce(&state, .key(.character("\u{07}")))
        _ = Reducer.reduce(&state, .key(.character("\u{9B}")))
        #expect(state.filterEditor?.text == "")
        type(&state, String(repeating: "a", count: FilterEditor.maxLength + 50))
        #expect(state.filterEditor?.text.count == FilterEditor.maxLength)
    }

    @Test func navigationStillWorksWhileEditing() {
        var state = makeState()
        load(&state, sequence: 1, sample)
        press(&state, .character("/"), .down, .down)
        #expect(state.selectedIndex == 2)
        #expect(state.filterEditor?.text == "")
    }

    @Test func reopeningTheEditorStartsFromTheCommittedText() {
        var state = makeState()
        press(&state, .character("/"))
        type(&state, "abc")
        press(&state, .enter, .character("/"))
        #expect(state.filterEditor?.text == "abc")
    }

    @Test func selectionLostToFilterMovesDeterministically() {
        var state = makeState()
        load(&state, sequence: 1, sample)
        press(&state, .down) // Safari
        press(&state, .character("/"))
        type(&state, "bash") // Safari filtered out; old position 1 -> next surviving row after it is bash
        #expect(state.selection == Fixtures.identity(3))
        press(&state, .escape) // restored: selection stays on bash, the identity still exists
        #expect(state.selection == Fixtures.identity(3))
    }

    @Test func filterSurvivesSnapshotsAndSelectionSurvivesProcessExit() {
        var state = makeState()
        load(&state, sequence: 1, sample)
        press(&state, .character("/"))
        type(&state, "user:shawn")
        press(&state, .enter, .down) // select bash
        load(&state, sequence: 2, [sample[0], sample[1]]) // bash exits
        #expect(state.rows.map(\.name) == ["Safari"])
        #expect(state.selection == Fixtures.identity(2))
    }

    @Test func noMatchesLeavesNoSelectionAndRecovers() {
        var state = makeState()
        load(&state, sequence: 1, sample)
        press(&state, .character("/"))
        type(&state, "zzz")
        #expect(state.rows.isEmpty && state.selection == nil)
        press(&state, .down, .pageDown, .home, .end) // no crash on an empty list
        press(&state, .ctrl("u"))
        #expect(state.rows.count == 3 && state.selection != nil)
    }

    // MARK: Pause

    @Test func pauseFreezesPresentationAndResumeShowsLatest() {
        var state = makeState()
        load(&state, sequence: 1, sample, cpu: 10)
        press(&state, .character(" "))
        #expect(state.isPaused)

        load(&state, sequence: 2, sample + [Fixtures.process(9, name: "new")], cpu: 90)
        load(&state, sequence: 3, sample + [Fixtures.process(9, name: "new")], cpu: 95)
        #expect(state.rows.count == 3)
        #expect(state.snapshot?.sequence == 1)
        #expect(state.cpuHistory.count == 1) // history is frozen too
        #expect(state.lastAcceptedSequence == 3) // but collection is still tracked

        press(&state, .character(" "))
        #expect(!state.isPaused && state.pendingSnapshot == nil)
        #expect(state.rows.count == 4)
        #expect(state.snapshot?.sequence == 3)
        #expect(state.cpuHistory.count == 2) // no replay of sequence 2, no filler
        #expect(state.cpuHistory.samples.map(\.value) == [.value(10), .value(95)])
    }

    @Test func pauseKeepsInputWorking() {
        var state = makeState()
        load(&state, sequence: 1, sample)
        press(&state, .character(" "), .down, .character("s"), .character("r"))
        #expect(state.selectedIndex != nil)
        #expect(state.sortKey == .name && state.sortDescending)
        #expect(Reducer.reduce(&state, .tick) == [.requestRefresh])
        #expect(Reducer.reduce(&state, .resize(TerminalSize(columns: 100, rows: 30))) == [])
        #expect(Reducer.reduce(&state, .key(.character("q"))) == [.exit])
    }

    @Test func resumeWithNothingPendingChangesNothing() {
        var state = makeState()
        load(&state, sequence: 1, sample)
        let before = state
        press(&state, .character(" "), .character(" "))
        #expect(state.rows == before.rows && state.snapshot == before.snapshot)
    }

    @Test func staleSnapshotsAreStillRejectedWhilePaused() {
        var state = makeState()
        load(&state, sequence: 5, sample)
        press(&state, .character(" "))
        load(&state, sequence: 4, sample + [Fixtures.process(9)])
        #expect(state.pendingSnapshot == nil)
    }

    // MARK: History and staleness

    @Test func historiesAreBoundedByCapacity() {
        var state = makeState(history: 5)
        for n in 1...20 { load(&state, sequence: UInt64(n), sample, cpu: Double(n)) }
        #expect(state.cpuHistory.count == 5)
        #expect(state.cpuHistory.samples.last?.value == .value(20))
    }

    @Test func unavailableCPUIsRecordedAsAGapNotZero() {
        var state = makeState()
        load(&state, sequence: 1, sample) // cpu is notYetSampled
        #expect(state.cpuHistory.samples.map(\.value) == [.unavailable(.notYetSampled)])
    }

    @Test func memoryHistoryRecordsApproximateUsedPercent() {
        var state = makeState()
        var snapshot = Fixtures.snapshot(1, sample)
        snapshot.memory = .value(MemoryReading(pageSizeBytes: 1000, activePages: 20, wiredPages: 10, compressorPages: 10))
        snapshot.physicalMemoryBytes = .value(100_000)
        _ = Reducer.reduce(&state, .snapshot(snapshot))
        #expect(state.memoryHistory.samples.first?.value == .value(40))

        snapshot.sequence = 2
        snapshot.physicalMemoryBytes = .unavailable(.unsupported)
        _ = Reducer.reduce(&state, .snapshot(snapshot))
        #expect(state.memoryHistory.samples.last?.value == .unavailable(.collectionFailed))
    }

    @Test func staleIndicatorAppearsAfterMissedTicksAndClearsOnSnapshot() {
        var state = makeState()
        for _ in 0..<5 { _ = Reducer.reduce(&state, .tick) }
        #expect(!state.isStale) // nothing collected yet is "collecting", not stale
        load(&state, sequence: 1, sample)
        #expect(!state.isStale)
        for _ in 0..<AppState.staleAfterTicks { _ = Reducer.reduce(&state, .tick) }
        #expect(state.isStale)
        load(&state, sequence: 2, sample)
        #expect(!state.isStale)
    }

    @Test func stalenessIsTrackedEvenWhilePaused() {
        var state = makeState()
        load(&state, sequence: 1, sample)
        press(&state, .character(" "))
        for n in 2...4 {
            _ = Reducer.reduce(&state, .tick)
            load(&state, sequence: UInt64(n), sample)
        }
        #expect(!state.isStale) // snapshots keep arriving while paused
    }

    // MARK: Layout

    @Test func pageSizeFollowsOverviewHeight() {
        #expect(ProcessTableLayout.overviewRows(for: TerminalSize(columns: 80, rows: 24)) == 7)
        #expect(ProcessTableLayout.visibleRows(for: TerminalSize(columns: 80, rows: 24)) == 15)
        #expect(ProcessTableLayout.overviewRows(for: TerminalSize(columns: 80, rows: 19)) == 1)
        #expect(ProcessTableLayout.overviewRows(for: TerminalSize(columns: 59, rows: 40)) == 1)
        #expect(ProcessTableLayout.visibleRows(for: TerminalSize(columns: 20, rows: 5)) == 2)
    }
}

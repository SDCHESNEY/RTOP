/// The only place application state changes. Pure: no OS calls, no clock, no I/O.
public enum Reducer {
    public static func reduce(_ state: inout AppState, _ action: Action) -> [Effect] {
        switch action {
        case .tick:
            state.ticksSinceSnapshot += 1
            return [.requestRefresh]

        case .terminate:
            return [.exit]

        case .resize(let size):
            state.terminalSize = size
            ensureSelectionVisible(&state)
            return []

        case .snapshot(let snapshot):
            let sequenceBefore = state.lastAcceptedSequence
            ingest(snapshot, into: &state)
            // Reload the open pane's details with each presented snapshot.
            return syncDetails(&state, reload: state.lastAcceptedSequence != sequenceBefore && !state.isPaused)

        case .detailsLoaded(let generation, let details):
            guard let pane = state.detailPane, pane.generation == generation, pane.identity == details.identity
            else { return [] } // stale: a newer request or another process owns the pane
            state.detailPane?.details = details
            state.detailCache.insert(details)
            return []

        case .signalResult(let request, let result):
            return finishSignal(request, result, in: &state)

        case .collectionFailed(let sequence, let message):
            guard sequence >= state.lastAcceptedSequence else { return [] }
            state.messages.removeAll { $0.kind == .refreshFailed } // keep only the latest failure
            state.messages.append(StatusMessage(kind: .refreshFailed, text: message))
            if state.messages.count > AppState.maxMessages {
                state.messages.removeFirst(state.messages.count - AppState.maxMessages)
            }
            return []

        case .key(let key):
            var effects = handle(key, in: &state)
            if effects.contains(.exit) { return effects }
            effects += syncDetails(&state, reload: false) // selection may have moved
            return effects
        }
    }

    // MARK: Keys

    private static func handle(_ key: KeyEvent, in state: inout AppState) -> [Effect] {
        if key == .ctrl("c") { return [.exit] }
        state.messages.removeAll { $0.kind == .signalResult } // a result is shown until the next key
        // Context precedence: see `KeyBindings.precedence`.
        if state.filterEditor != nil { return handleFilterEditing(key, in: &state) }
        if state.signalWorkflow != nil { return handleSignalDialog(key, in: &state) }
        if state.showHelp { return handleHelp(key, in: &state) }

        switch key {
        case .character("q"):
            return [.exit]
        case .escape: // closes the pane if one is open; quits when no context is active
            if state.detailPane != nil {
                state.detailPane = nil
                return []
            }
            return [.exit]
        case .character("s"):
            state.sortKey = state.sortKey.next
            rebuildRows(&state)
        case .character("r"):
            state.sortDescending.toggle()
            rebuildRows(&state)
        case .character("/"):
            state.filterEditor = FilterEditor(
                text: state.filterText, originalFilter: state.filter, originalText: state.filterText)
        case .character(" "):
            togglePause(&state)
        case .character("t"):
            state.treeMode.toggle()
            rebuildRows(&state)
        case .character("d"):
            if state.detailPane != nil { state.detailPane = nil; return [] }
            return openDetails(&state)
        case .enter:
            return state.detailPane == nil ? openDetails(&state) : []
        case .character("x"):
            openSignalDialog(&state)
        case .character("?"):
            state.showHelp = true
        default:
            navigate(key, in: &state)
        }
        return []
    }

    // MARK: Help

    private static func handleHelp(_ key: KeyEvent, in state: inout AppState) -> [Effect] {
        switch key {
        case .escape, .character("?"), .character("q"), .enter: state.showHelp = false
        default: break
        }
        return []
    }

    // MARK: Details

    /// The row selection can target: a real process (not the "Unattached" group).
    private static func selectedProcess(_ state: AppState) -> ProcessSummary? {
        guard let index = state.selectedIndex, !state.rows[index].isSynthetic else { return nil }
        return state.rows[index]
    }

    private static func openDetails(_ state: inout AppState) -> [Effect] {
        guard let process = selectedProcess(state) else { return [] }
        state.detailPane = DetailPane(
            identity: process.identity, generation: 0, details: state.detailCache.lookup(process.identity))
        return requestDetails(&state)
    }

    /// Every request gets a fresh generation, so older replies are discarded.
    private static func requestDetails(_ state: inout AppState) -> [Effect] {
        guard let pane = state.detailPane else { return [] }
        state.detailGeneration += 1
        state.detailPane?.generation = state.detailGeneration
        return [.loadDetails(identity: pane.identity, generation: state.detailGeneration)]
    }

    /// Keeps the open pane on the selected process, and reloads on request.
    private static func syncDetails(_ state: inout AppState, reload: Bool) -> [Effect] {
        guard let pane = state.detailPane else { return [] }
        guard let process = selectedProcess(state) else {
            state.detailPane = nil // nothing real is selected
            return []
        }
        if pane.identity != process.identity {
            state.detailPane = DetailPane(
                identity: process.identity, generation: 0, details: state.detailCache.lookup(process.identity))
            return requestDetails(&state)
        }
        return reload ? requestDetails(&state) : []
    }

    private static func navigate(_ key: KeyEvent, in state: inout AppState) {
        let page = max(1, ProcessTableLayout.visibleRows(for: state.terminalSize))
        switch key {
        case .up, .character("k"): move(&state, by: -1)
        case .down, .character("j"): move(&state, by: 1)
        case .pageUp: move(&state, by: -page)
        case .pageDown: move(&state, by: page)
        case .home: select(&state, index: 0)
        case .end: select(&state, index: state.rows.count - 1)
        default: break
        }
    }

    // MARK: Signal dialog

    private static func openSignalDialog(_ state: inout AppState) {
        guard let process = selectedProcess(state) else {
            postSignalMessage(&state, "Select a process first.")
            return
        }
        // Refuse what can never be delivered, before asking the user anything.
        if let refusal = ProcessControlPolicy.validate(pid: process.identity.pid, ownPID: state.ownPID) {
            postSignalMessage(&state, describe(refusal, name: process.name, signal: nil))
            return
        }
        guard process.identity.start != nil else {
            postSignalMessage(&state, describe(.identityUnavailable, name: process.name, signal: nil))
            return
        }
        let request = SignalRequest(
            identity: process.identity, name: process.name, uid: process.uid.value,
            path: process.executablePath.value)
        state.signalWorkflow = SignalWorkflow(request: request, stage: .confirm, notice: nil)
    }

    /// While the dialog is open it owns every key; unknown keys do nothing.
    private static func handleSignalDialog(_ key: KeyEvent, in state: inout AppState) -> [Effect] {
        guard var workflow = state.signalWorkflow, workflow.stage != .sending else { return [] }
        switch key {
        case .left, .right:
            // A different signal is a different decision: confirmation starts over.
            workflow.request.signal = workflow.request.signal.advanced(by: key == .right ? 1 : -1)
            workflow.stage = .confirm
            workflow.notice = nil
            state.signalWorkflow = workflow
        case .character("n"), .escape:
            state.signalWorkflow = nil
        case .enter, .character("y"):
            switch workflow.stage {
            case .confirm:
                if workflow.request.isProtected {
                    workflow.stage = .confirmProtected
                    workflow.notice = nil
                    state.signalWorkflow = workflow
                } else {
                    return beginSending(workflow, in: &state)
                }
            case .confirmProtected:
                // The second stage is distinct: only an explicit `y`, never Enter.
                guard key == .character("y") else { return [] }
                return beginSending(workflow, in: &state)
            case .sending:
                break
            }
        default:
            break
        }
        return []
    }

    private static func beginSending(_ workflow: SignalWorkflow, in state: inout AppState) -> [Effect] {
        var workflow = workflow
        workflow.stage = .sending
        workflow.notice = nil
        state.signalWorkflow = workflow
        return [.sendSignal(workflow.request)]
    }

    private static func finishSignal(
        _ request: SignalRequest, _ result: Result<SignalSent, ControlError>, in state: inout AppState
    ) -> [Effect] {
        guard let workflow = state.signalWorkflow, workflow.stage == .sending, workflow.request == request
        else { return [] }
        switch result {
        case .success(let sent):
            state.signalWorkflow = nil
            postSignalMessage(&state, "Signal sent: \(sent.signal.name) to pid \(sent.pid) (\(request.name)). "
                + "The system accepted it; the process may still be running.")
        case .failure(.cautionChanged):
            // Ownership or location changed since confirmation: ask again, as protected.
            var next = workflow
            next.request.isProtected = true
            next.stage = .confirm
            next.notice = "This process changed since you confirmed. Confirm again."
            state.signalWorkflow = next
            return []
        case .failure(let error):
            state.signalWorkflow = nil
            postSignalMessage(&state, describe(error, name: request.name, signal: request.signal))
        }
        return [.requestRefresh] // observe the effect promptly
    }

    static func describe(_ error: ControlError, name: String, signal: ControlSignal?) -> String {
        switch error {
        case .invalidTarget: "Not a valid process ID; nothing was sent."
        case .protectedTarget: "\(name) is protected (PID 1 or this monitor); nothing was sent."
        case .permissionDenied: "Permission denied: this user may not signal \(name)."
        case .processExited: "\(name) no longer exists; nothing was sent."
        case .identityChanged: "That PID now belongs to a different process; nothing was sent."
        case .identityUnavailable: "\(name) cannot be verified (its start time is unreadable); nothing was sent."
        case .cautionChanged: "\(name) changed since you confirmed; nothing was sent."
        case .osFailure(let code): "Sending \(signal?.name ?? "the signal") failed (errno \(code))."
        }
    }

    private static func postSignalMessage(_ state: inout AppState, _ text: String) {
        state.messages.removeAll { $0.kind == .signalResult }
        state.messages.append(StatusMessage(kind: .signalResult, text: text))
        if state.messages.count > AppState.maxMessages {
            state.messages.removeFirst(state.messages.count - AppState.maxMessages)
        }
    }

    // MARK: Filter editing

    /// While editing, letters are text, not commands (`q` and `k` included).
    /// Only Ctrl-C (handled earlier) still quits. Arrow/page keys keep navigating.
    private static func handleFilterEditing(_ key: KeyEvent, in state: inout AppState) -> [Effect] {
        guard var editor = state.filterEditor else { return [] }
        switch key {
        case .character(let ch):
            guard editor.text.count < FilterEditor.maxLength, !ch.unicodeScalars.contains(where: isControl) else {
                return []
            }
            editor.text.append(ch)
            applyEditorText(&editor, to: &state)
        case .backspace, .delete:
            guard !editor.text.isEmpty else { return [] }
            editor.text.removeLast()
            applyEditorText(&editor, to: &state)
        case .ctrl("u"):
            editor.text = ""
            applyEditorText(&editor, to: &state)
        case .enter:
            // Only a valid text commits; an invalid one stays open with its error.
            if editor.error == nil { state.filterEditor = nil }
        case .escape:
            state.filter = editor.originalFilter
            state.filterText = editor.originalText
            state.filterEditor = nil
            rebuildRows(&state)
        default:
            navigate(key, in: &state)
        }
        return []
    }

    private static func applyEditorText(_ editor: inout FilterEditor, to state: inout AppState) {
        switch ProcessFilter.parse(editor.text) {
        case .success(let filter):
            editor.error = nil
            state.filter = filter
            state.filterText = editor.text
            state.filterEditor = editor
            rebuildRows(&state)
        case .failure(let error):
            editor.error = error.description // the last valid filter stays active
            state.filterEditor = editor
        }
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }

    // MARK: Pause

    /// Pause freezes what is presented (rows, selection context, histories);
    /// snapshots keep arriving so the sampler's baselines stay valid. Resume
    /// presents the newest snapshot only: no replay, no filler samples.
    private static func togglePause(_ state: inout AppState) {
        state.isPaused.toggle()
        guard !state.isPaused, let pending = state.pendingSnapshot else { return }
        state.pendingSnapshot = nil
        present(pending, in: &state)
    }

    private static func move(_ state: inout AppState, by delta: Int) {
        guard !state.rows.isEmpty else { return }
        guard let current = state.selectedIndex else {
            select(&state, index: 0)
            return
        }
        select(&state, index: current + delta)
    }

    private static func select(_ state: inout AppState, index: Int) {
        guard !state.rows.isEmpty else { return }
        let clamped = min(max(index, 0), state.rows.count - 1)
        state.selection = state.rows[clamped].identity
        ensureSelectionVisible(&state)
    }

    // MARK: Snapshots

    private static func ingest(_ snapshot: Snapshot, into state: inout AppState) {
        guard snapshot.sequence > state.lastAcceptedSequence else { return } // stale or duplicate
        state.lastAcceptedSequence = snapshot.sequence
        state.ticksSinceSnapshot = 0
        state.messages.removeAll { $0.kind == .refreshFailed }

        if state.isPaused {
            state.pendingSnapshot = snapshot
        } else {
            present(snapshot, in: &state)
        }
    }

    private static func present(_ snapshot: Snapshot, in state: inout AppState) {
        state.snapshot = snapshot
        recordHistory(snapshot, in: &state)
        rebuildRows(&state)
        cancelDialogIfTargetGone(&state, snapshot)
    }

    /// A confirmation for a process that has exited (or whose PID was reused,
    /// which changes the identity) is void. Checked against the unfiltered set.
    private static func cancelDialogIfTargetGone(_ state: inout AppState, _ snapshot: Snapshot) {
        guard let workflow = state.signalWorkflow, workflow.stage != .sending else { return }
        if !snapshot.processes.contains(where: { $0.identity == workflow.request.identity }) {
            state.signalWorkflow = nil
            postSignalMessage(&state, "\(workflow.request.name) exited; the signal was cancelled.")
        }
    }

    private static func recordHistory(_ snapshot: Snapshot, in state: inout AppState) {
        let at = snapshot.capturedAtNanoseconds
        state.cpuHistory.append(snapshot.cpu.map(\.aggregatePercent), atNanoseconds: at)

        var memory: Availability<Double>
        switch snapshot.memory {
        case .unavailable(let reason): memory = .unavailable(reason)
        case .value(let reading):
            memory = .unavailable(.collectionFailed)
            if let used = MemoryMath.approximateUsedBytes(reading),
               case .value(let total) = snapshot.physicalMemoryBytes,
               let fraction = MemoryMath.fraction(used, of: total) {
                memory = .value(fraction * 100)
            }
        }
        state.memoryHistory.append(memory, atNanoseconds: at)
    }

    /// Rebuilds `rows` from the presented snapshot (filter, then sort).
    /// Selection follows the process identity. If the selected process is gone
    /// (exited or filtered out), the rule is: the first surviving row *after*
    /// its old position, else the nearest surviving row before it, else the
    /// first row. Deterministic for a given old/new pair.
    private static func rebuildRows(_ state: inout AppState) {
        let oldRows = state.rows
        let oldIndex = state.selectedIndex

        let source = state.snapshot?.processes ?? []
        if state.treeMode {
            let nodes = ProcessTree.layout(
                source, filter: state.filter, key: state.sortKey, descending: state.sortDescending)
            state.rows = nodes.map(\.process)
            state.rowDepths = nodes.map(\.depth)
            state.contextRows = Set(nodes.lazy.filter(\.isContext).map(\.process.identity))
        } else {
            state.rows = ProcessSort.sorted(
                state.filter.apply(to: source), by: state.sortKey, descending: state.sortDescending)
            state.rowDepths = []
            state.contextRows = []
        }

        let survivors = Set(state.rows.map(\.identity))
        if let selection = state.selection, !survivors.contains(selection) {
            state.selection = nearestSurvivor(oldRows: oldRows, oldIndex: oldIndex, survivors: survivors)
        }
        if state.selection == nil { state.selection = state.rows.first?.identity }
        ensureSelectionVisible(&state)
    }

    private static func nearestSurvivor(
        oldRows: [ProcessSummary], oldIndex: Int?, survivors: Set<ProcessIdentity>
    ) -> ProcessIdentity? {
        guard let oldIndex else { return nil }
        for row in oldRows[(oldIndex + 1)...] where survivors.contains(row.identity) { return row.identity }
        for row in oldRows[..<oldIndex].reversed() where survivors.contains(row.identity) { return row.identity }
        return nil
    }

    // MARK: Scrolling

    /// Clamps the scroll offset and keeps the selected row inside the window.
    private static func ensureSelectionVisible(_ state: inout AppState) {
        let visible = ProcessTableLayout.visibleRows(for: state.terminalSize)
        guard visible > 0, !state.rows.isEmpty else {
            state.scrollOffset = 0
            return
        }
        var offset = min(max(state.scrollOffset, 0), max(0, state.rows.count - visible))
        if let index = state.selectedIndex {
            if index < offset { offset = index }
            if index >= offset + visible { offset = index - visible + 1 }
        }
        state.scrollOffset = offset
    }
}

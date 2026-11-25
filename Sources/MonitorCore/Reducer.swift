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
            ingest(snapshot, into: &state)
            return []

        case .collectionFailed(let sequence, let message):
            guard sequence >= state.lastAcceptedSequence else { return [] }
            state.messages.removeAll { $0.kind == .refreshFailed } // keep only the latest failure
            state.messages.append(StatusMessage(kind: .refreshFailed, text: message))
            if state.messages.count > AppState.maxMessages {
                state.messages.removeFirst(state.messages.count - AppState.maxMessages)
            }
            return []

        case .key(let key):
            return handle(key, in: &state)
        }
    }

    // MARK: Keys

    private static func handle(_ key: KeyEvent, in state: inout AppState) -> [Effect] {
        if key == .ctrl("c") { return [.exit] }
        if state.filterEditor != nil { return handleFilterEditing(key, in: &state) }

        switch key {
        case .character("q"), .escape: // Escape quits when no modal/filter context is active
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
        default:
            navigate(key, in: &state)
        }
        return []
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
        state.rows = ProcessSort.sorted(
            state.filter.apply(to: source), by: state.sortKey, descending: state.sortDescending)

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

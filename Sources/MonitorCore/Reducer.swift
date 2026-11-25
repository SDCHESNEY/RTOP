/// The only place application state changes. Pure: no OS calls, no clock, no I/O.
public enum Reducer {
    public static func reduce(_ state: inout AppState, _ action: Action) -> [Effect] {
        switch action {
        case .tick:
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
        let page = max(1, ProcessTableLayout.visibleRows(for: state.terminalSize))
        switch key {
        case .character("q"), .ctrl("c"), .escape: // Escape quits when no modal/filter context is active
            return [.exit]
        case .up, .character("k"): move(&state, by: -1)
        case .down, .character("j"): move(&state, by: 1)
        case .pageUp: move(&state, by: -page)
        case .pageDown: move(&state, by: page)
        case .home: select(&state, index: 0)
        case .end: select(&state, index: state.rows.count - 1)
        default: break
        }
        return []
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

    /// Selection follows the process identity. If the selected process is gone,
    /// the rule is: the first surviving row *after* its old position, else the
    /// nearest surviving row before it, else the first row. Deterministic for
    /// a given old/new pair.
    private static func ingest(_ snapshot: Snapshot, into state: inout AppState) {
        guard snapshot.sequence > state.lastAcceptedSequence else { return } // stale or duplicate
        state.lastAcceptedSequence = snapshot.sequence
        state.snapshot = snapshot
        state.messages.removeAll { $0.kind == .refreshFailed }

        let oldRows = state.rows
        let oldIndex = state.selectedIndex
        let newRows = snapshot.processes.sorted {
            if $0.identity.pid != $1.identity.pid { return $0.identity.pid < $1.identity.pid }
            return ($0.identity.start ?? ProcessStartTime(seconds: 0, microseconds: 0))
                < ($1.identity.start ?? ProcessStartTime(seconds: 0, microseconds: 0))
        }
        state.rows = newRows

        let survivors = Set(newRows.map(\.identity))
        if let selection = state.selection, !survivors.contains(selection) {
            state.selection = nearestSurvivor(oldRows: oldRows, oldIndex: oldIndex, survivors: survivors)
        }
        if state.selection == nil { state.selection = newRows.first?.identity }
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

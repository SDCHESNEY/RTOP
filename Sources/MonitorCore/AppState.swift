public struct TerminalSize: Sendable, Equatable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

public enum KeyEvent: Sendable, Equatable {
    case character(Character)
    case ctrl(Character)   // lowercase letter, e.g. .ctrl("c")
    case up, down, left, right
    case pageUp, pageDown, home, end
    case enter, escape, tab, backspace, delete
    case unknown
}

/// Row geometry shared by the reducer (scroll) and the renderer so the two
/// can never disagree about how many rows are visible.
public enum ProcessTableLayout {
    public static let headerRows = 1
    public static let footerRows = 1
    /// Title, CPU, cores, memory, two memory-category rows, swap/pressure.
    public static let fullOverviewRows = 7
    public static let minimumOverviewColumns = 60
    public static let minimumOverviewRows = 20
    /// Columns at which the table gains its extra (PPID) column and histories widen.
    public static let wideColumns = 100

    /// Small terminals get a one-line title instead of the full overview.
    public static func overviewRows(for size: TerminalSize) -> Int {
        size.columns >= minimumOverviewColumns && size.rows >= minimumOverviewRows ? fullOverviewRows : 1
    }

    public static func visibleRows(for size: TerminalSize) -> Int {
        max(0, size.rows - overviewRows(for: size) - headerRows - footerRows)
    }
}

/// In-progress edit of the live filter. The edited text applies as it is typed
/// while it parses; an invalid text keeps the last valid filter and records `error`.
public struct FilterEditor: Sendable, Equatable {
    public static let maxLength = 256

    public var text: String
    public var error: String?
    /// Restored by Escape.
    public var originalFilter: ProcessFilter
    public var originalText: String

    public init(text: String, originalFilter: ProcessFilter, originalText: String) {
        self.text = text
        self.error = nil
        self.originalFilter = originalFilter
        self.originalText = originalText
    }
}

/// The open detail pane. `details` is nil while loading. A reply is accepted
/// only if it carries this pane's identity *and* generation.
public struct DetailPane: Sendable, Equatable {
    public var identity: ProcessIdentity
    public var generation: UInt64
    public var details: ProcessDetails?
}

/// Where the signal dialog is in its confirmation sequence:
/// `confirm` (stage 1) → `confirmProtected` (stage 2, protected targets only)
/// → `sending` → closed, with the outcome as a status message.
public struct SignalWorkflow: Sendable, Equatable {
    public enum Stage: Sendable, Equatable { case confirm, confirmProtected, sending }

    public var request: SignalRequest
    public var stage: Stage
    /// Shown in the dialog, e.g. after a revalidation sent the user back to stage 1.
    public var notice: String?
}

public struct StatusMessage: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case refreshFailed, signalResult }
    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct AppState: Sendable, Equatable {
    public static let maxMessages = 5

    /// The snapshot being presented. While paused it is frozen at the pause point.
    public var snapshot: Snapshot?
    /// Rows in display order: `snapshot` filtered, then sorted.
    public var rows: [ProcessSummary] = []
    public var sortKey: SortKey = .pid
    public var sortDescending = false
    /// The active filter and the text it was parsed from.
    public var filter: ProcessFilter = .empty
    public var filterText = ""
    public var filterEditor: FilterEditor?
    public var isPaused = false
    /// Newest snapshot received while paused; presented on resume.
    public var pendingSnapshot: Snapshot?
    /// Ticks since a snapshot was last accepted (paused or not); drives the stale indicator.
    public var ticksSinceSnapshot = 0
    public var cpuHistory: HistoryBuffer<Double>
    public var memoryHistory: HistoryBuffer<Double>
    public var lastAcceptedSequence: UInt64 = 0
    public var selection: ProcessIdentity?
    public var scrollOffset = 0
    public var terminalSize: TerminalSize
    /// Show processes as a parent/child tree. Sort applies among siblings.
    public var treeMode = false
    /// Parallel to `rows`; empty outside tree mode.
    public var rowDepths: [Int] = []
    /// Tree rows shown only as ancestors of a filter match.
    public var contextRows: Set<ProcessIdentity> = []
    public var detailPane: DetailPane?
    public var detailGeneration: UInt64 = 0
    public var detailCache = DetailCache()
    public var signalWorkflow: SignalWorkflow?
    public var showHelp = false
    /// The monitor's own PID, which it refuses to signal. 0 = unknown (refuses nothing extra).
    public var ownPID: Int32 = 0
    public var messages: [StatusMessage] = []
    public var refreshIntervalMilliseconds: Int

    public static let staleAfterTicks = 3

    public init(
        terminalSize: TerminalSize, refreshIntervalMilliseconds: Int = 1000, historyCapacity: Int = 60
    ) {
        self.terminalSize = terminalSize
        self.refreshIntervalMilliseconds = refreshIntervalMilliseconds
        self.cpuHistory = HistoryBuffer(capacity: historyCapacity)
        self.memoryHistory = HistoryBuffer(capacity: historyCapacity)
    }

    /// True when collection has not delivered a snapshot for several refresh intervals.
    public var isStale: Bool { snapshot != nil && ticksSinceSnapshot >= Self.staleAfterTicks }

    public var selectedIndex: Int? {
        guard let selection else { return nil }
        return rows.firstIndex { $0.identity == selection }
    }
}

public enum Action: Sendable, Equatable {
    case key(KeyEvent)
    case snapshot(Snapshot)
    case collectionFailed(sequence: UInt64, message: String)
    case resize(TerminalSize)
    case tick
    /// A lazy detail read finished. Ignored unless identity and generation match the open pane.
    case detailsLoaded(generation: UInt64, details: ProcessDetails)
    /// Outcome of an `Effect.sendSignal` for exactly this request.
    case signalResult(request: SignalRequest, result: Result<SignalSent, ControlError>)
    /// SIGINT/SIGTERM/SIGHUP, or loss of the input stream.
    case terminate
}

public enum Effect: Sendable, Equatable {
    case requestRefresh
    case loadDetails(identity: ProcessIdentity, generation: UInt64)
    /// Handled by the store with a `ProcessControlling`; the outcome returns as `.signalResult`.
    case sendSignal(SignalRequest)
    case exit
}

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

public struct StatusMessage: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case refreshFailed }
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
    /// SIGINT/SIGTERM/SIGHUP, or loss of the input stream.
    case terminate
}

public enum Effect: Sendable, Equatable {
    case requestRefresh
    case exit
}

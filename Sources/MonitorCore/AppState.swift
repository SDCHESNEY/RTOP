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
    public static let titleRows = 1
    public static let headerRows = 1
    public static let footerRows = 1

    public static func visibleRows(for size: TerminalSize) -> Int {
        max(0, size.rows - titleRows - headerRows - footerRows)
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

    public var snapshot: Snapshot?
    /// Rows in display order (PID ascending until Phase 2 adds sorting).
    public var rows: [ProcessSummary] = []
    public var lastAcceptedSequence: UInt64 = 0
    public var selection: ProcessIdentity?
    public var scrollOffset = 0
    public var terminalSize: TerminalSize
    public var messages: [StatusMessage] = []
    public var refreshIntervalMilliseconds: Int

    public init(terminalSize: TerminalSize, refreshIntervalMilliseconds: Int = 1000) {
        self.terminalSize = terminalSize
        self.refreshIntervalMilliseconds = refreshIntervalMilliseconds
    }

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

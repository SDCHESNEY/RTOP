import Darwin
import MonitorCore

public enum TerminalError: Error, Equatable, CustomStringConvertible {
    case notATerminal
    case system(operation: String, errno: Int32)

    public var description: String {
        switch self {
        case .notATerminal: "standard input and output must both be terminals"
        case .system(let op, let e): "\(op) failed: \(String(cString: strerror(e)))"
        }
    }
}

/// Owns raw-mode terminal state for the lifetime of the session.
///
/// Phase 0 proof of concept: saves the exact original `termios`, enters raw
/// mode and the alternate screen, and restores everything idempotently.
/// `deinit` restores as a safety net, but it is not a guarantee after a fatal
/// runtime failure or SIGKILL (see the manual recovery note in the README).
public final class TerminalSession {
    private let inputFD: Int32
    private let outputFD: Int32
    private var saved = termios()
    private var active = false

    /// Escape sequences emitted on entry/exit.
    /// Alternate screen, hidden cursor, autowrap off (so painting the last
    /// cell can never scroll the screen).
    static let enterSequence = "\u{1B}[?1049h\u{1B}[?25l\u{1B}[?7l"
    /// Resets styling, re-enables autowrap, defensively turns every mouse mode
    /// off (the app never enables them), shows the cursor, leaves the alternate screen.
    static let exitSequence = "\u{1B}[0m\u{1B}[?7h\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l\u{1B}[?25h\u{1B}[?1049l"

    public init(inputFD: Int32 = STDIN_FILENO, outputFD: Int32 = STDOUT_FILENO) {
        self.inputFD = inputFD
        self.outputFD = outputFD
    }

    deinit { restore() }

    public var isActive: Bool { active }

    public func enter() throws {
        guard !active else { return }
        guard isatty(inputFD) == 1, isatty(outputFD) == 1 else { throw TerminalError.notATerminal }
        guard tcgetattr(inputFD, &saved) == 0 else {
            throw TerminalError.system(operation: "tcgetattr", errno: errno)
        }
        var raw = saved
        cfmakeraw(&raw)
        // Reads return as soon as any byte is available; the caller polls.
        withUnsafeMutableBytes(of: &raw.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        guard tcsetattr(inputFD, TCSAFLUSH, &raw) == 0 else {
            throw TerminalError.system(operation: "tcsetattr", errno: errno)
        }
        active = true
        write(Self.enterSequence)
    }

    /// Restores the exact saved settings. Safe to call repeatedly.
    public func restore() {
        guard active else { return }
        active = false
        write(Self.exitSequence)
        var s = saved
        _ = tcsetattr(inputFD, TCSAFLUSH, &s)
    }

    /// Current window size, or nil when it cannot be read.
    public func size() -> TerminalSize? { Self.querySize(fd: outputFD) }

    /// Window size of the terminal on `fd`; usable from any thread.
    public static func querySize(fd: Int32) -> TerminalSize? {
        var ws = winsize()
        guard ioctl(fd, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 else { return nil }
        return TerminalSize(columns: Int(ws.ws_col), rows: Int(ws.ws_row))
    }

    /// Writes all bytes, handling short writes and EINTR. On EAGAIN it waits
    /// for the descriptor to become writable. Returns false if the terminal
    /// is gone (EPIPE, EIO, ...).
    @discardableResult
    public func write(_ text: String) -> Bool {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let n = bytes.withUnsafeBytes { Darwin.write(outputFD, $0.baseAddress, $0.count) }
            if n > 0 {
                bytes = bytes.dropFirst(n)
            } else if n < 0 && errno == EINTR {
                continue
            } else if n < 0 && errno == EAGAIN {
                var p = pollfd(fd: outputFD, events: Int16(POLLOUT), revents: 0)
                _ = poll(&p, 1, 100)
            } else {
                return false
            }
        }
        return true
    }
}

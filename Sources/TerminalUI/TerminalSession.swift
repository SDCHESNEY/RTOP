import Darwin

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
    static let enterSequence = "\u{1B}[?1049h\u{1B}[?25l"
    static let exitSequence = "\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l"

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

    /// Writes all bytes, handling short writes and EINTR/EAGAIN.
    @discardableResult
    public func write(_ text: String) -> Bool {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let n = bytes.withUnsafeBytes { Darwin.write(outputFD, $0.baseAddress, $0.count) }
            if n > 0 {
                bytes = bytes.dropFirst(n)
            } else if n < 0 && (errno == EINTR || errno == EAGAIN) {
                continue
            } else {
                return false
            }
        }
        return true
    }
}

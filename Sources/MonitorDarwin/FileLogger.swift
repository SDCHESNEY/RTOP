import Darwin
import Foundation

/// Diagnostic log: one line per event, owner-only (file 0600, directory 0700),
/// size-rotated with a retention cap, never written to the terminal.
///
/// Callers pass short fixed-purpose messages. Command lines, environment
/// values, and process listings are never logged. Every message is
/// sanitized (control characters, length) before it is written so process-derived
/// text cannot forge log lines. A log that cannot be opened silently disables itself.
///
/// `@unchecked Sendable` invariant: every stored property other than the
/// immutable configuration is read and written only on `queue`.
public final class FileLogger: @unchecked Sendable {
    public enum Level: String, Sendable { case info, warning, error }

    public struct Policy: Sendable, Equatable {
        public var maxBytes: Int
        /// Rotated files kept besides the active one (`rtop.log.1` … `.N`).
        public var retainedFiles: Int
        /// A repeated `rateLimitKey` is written at most once per interval.
        public var minimumRepeatInterval: TimeInterval

        public static let standard = Policy(maxBytes: 256 * 1024, retainedFiles: 3, minimumRepeatInterval: 60)

        public init(maxBytes: Int, retainedFiles: Int, minimumRepeatInterval: TimeInterval) {
            self.maxBytes = max(256, maxBytes)
            self.retainedFiles = max(0, retainedFiles)
            self.minimumRepeatInterval = minimumRepeatInterval
        }
    }

    public static let maxMessageScalars = 300

    private let directory: URL
    private let policy: Policy
    private let clock: @Sendable () -> Date
    private let queue = DispatchQueue(label: "rtop.log")
    private var descriptor: Int32 = -1
    private var disabled = false
    private var lastEmitted: [String: Date] = [:]
    private var suppressed: [String: Int] = [:]
    private lazy var formatter = ISO8601DateFormatter()

    private var logURL: URL { directory.appendingPathComponent("rtop.log") }

    public init(directory: URL, policy: Policy = .standard, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.policy = policy
        self.clock = clock
    }

    /// `~/Library/Logs/rtop` under `home`.
    public static func standardDirectory(home: URL) -> URL {
        home.appendingPathComponent("Library/Logs/rtop", isDirectory: true)
    }

    /// Queues a line and returns immediately.
    public func log(_ level: Level, _ message: String, rateLimitKey: String? = nil) {
        queue.async { self.write(level, message, rateLimitKey) }
    }

    /// Waits for queued lines and closes the file. Call before exit.
    public func flush() {
        queue.sync {
            if descriptor >= 0 { close(descriptor); descriptor = -1 }
        }
    }

    // MARK: Queue-confined

    private func write(_ level: Level, _ message: String, _ key: String?) {
        guard !disabled else { return }
        let now = clock()
        var text = Self.sanitize(message)
        if let key {
            if let last = lastEmitted[key], now.timeIntervalSince(last) < policy.minimumRepeatInterval {
                suppressed[key, default: 0] += 1
                return
            }
            lastEmitted[key] = now
            if let count = suppressed.removeValue(forKey: key), count > 0 {
                text += " (\(count) similar suppressed)"
            }
        }
        let line = "\(formatter.string(from: now)) \(level.rawValue) \(text)\n"
        let bytes = Array(line.utf8)
        guard openIfNeeded() else { return }
        rotateIfNeeded(adding: bytes.count)
        guard openIfNeeded() else { return }

        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EINTR { continue }
                disabled = true
                return
            }
            offset += written
        }
    }

    private func openIfNeeded() -> Bool {
        if descriptor >= 0 { return true }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            disabled = true
            return false
        }
        // Tighten a directory we own that was created earlier with a looser mode.
        var info = stat()
        if stat(directory.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 != 0 {
            chmod(directory.path, 0o700)
        }
        // O_NOFOLLOW: never write through a symlink planted at the log path.
        let fd = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { disabled = true; return false }
        fchmod(fd, 0o600) // tighten a file created earlier with a looser mode
        descriptor = fd
        return true
    }

    private func rotateIfNeeded(adding count: Int) {
        guard descriptor >= 0 else { return }
        var info = stat()
        guard fstat(descriptor, &info) == 0, Int(info.st_size) + count > policy.maxBytes, info.st_size > 0 else { return }
        close(descriptor)
        descriptor = -1
        let fm = FileManager.default
        let base = logURL.path
        if policy.retainedFiles == 0 {
            try? fm.removeItem(atPath: base)
            return
        }
        try? fm.removeItem(atPath: "\(base).\(policy.retainedFiles)")
        for index in stride(from: policy.retainedFiles - 1, through: 1, by: -1) {
            try? fm.moveItem(atPath: "\(base).\(index)", toPath: "\(base).\(index + 1)")
        }
        try? fm.moveItem(atPath: base, toPath: "\(base).1")
    }

    /// Control characters and line breaks become `?`; length is bounded.
    static func sanitize(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for (count, scalar) in text.unicodeScalars.enumerated() {
            if count >= maxMessageScalars { break }
            switch scalar.value {
            case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029, 0x202A...0x202E, 0x2066...0x2069: out.append("?")
            default: out.append(scalar)
            }
        }
        return String(out)
    }
}

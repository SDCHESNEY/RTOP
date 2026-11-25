import Foundation

/// Slow-changing, per-process data read on demand for the detail pane. Every
/// field is independently available or carries the reason it is not.
public struct ProcessDetails: Sendable, Equatable {
    public var identity: ProcessIdentity
    /// Arguments only (environment is never read into this type). Missing is
    /// unavailable; the process name is never substituted for it.
    public var commandLine: Availability<CommandLine>
    public var threadCount: Availability<Int32>
    public var virtualBytes: Availability<UInt64>

    public init(
        identity: ProcessIdentity,
        commandLine: Availability<CommandLine>,
        threadCount: Availability<Int32> = .unavailable(.collectionFailed),
        virtualBytes: Availability<UInt64> = .unavailable(.collectionFailed)
    ) {
        self.identity = identity
        self.commandLine = commandLine
        self.threadCount = threadCount
        self.virtualBytes = virtualBytes
    }

    /// Every field unavailable for one reason (e.g. the process is gone).
    public static func unavailable(_ identity: ProcessIdentity, _ reason: UnavailableReason) -> ProcessDetails {
        ProcessDetails(
            identity: identity, commandLine: .unavailable(reason),
            threadCount: .unavailable(reason), virtualBytes: .unavailable(reason))
    }

    public struct CommandLine: Sendable, Equatable {
        public var arguments: [String]
        /// The kernel buffer or the argument count limit cut the list short.
        public var truncated: Bool

        public init(arguments: [String], truncated: Bool = false) {
            self.arguments = arguments
            self.truncated = truncated
        }
    }
}

/// Parser for the `KERN_PROCARGS2` byte format:
///
///     int32 argc (native byte order)
///     executable path, NUL-terminated
///     NUL padding
///     argc arguments, each NUL-terminated
///     environment strings (never decoded or retained)
///
/// Pure and bounds-checked; hostile or truncated input yields a result or an
/// error, never a trap.
public enum ProcArgsParser {
    public static let maxArguments = 4096
    public static let maxArgumentBytes = 64 * 1024

    public struct Parsed: Sendable, Equatable {
        public var executablePath: String
        public var commandLine: ProcessDetails.CommandLine
    }

    public enum ParseError: Error, Sendable, Equatable {
        /// Fewer than four bytes: no argument count.
        case tooShort
        /// Negative or absurd argument count.
        case invalidArgumentCount(Int32)
        /// No NUL ended the executable path.
        case unterminatedPath
    }

    public static func parse(_ bytes: [UInt8]) -> Result<Parsed, ParseError> {
        guard bytes.count >= 4 else { return .failure(.tooShort) }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0, argc <= Int32(maxArguments) else { return .failure(.invalidArgumentCount(argc)) }

        var index = 4
        guard let pathEnd = bytes[index...].firstIndex(of: 0) else { return .failure(.unterminatedPath) }
        let path = decode(bytes[index..<pathEnd])
        index = pathEnd
        while index < bytes.count, bytes[index] == 0 { index += 1 } // padding

        var arguments = [String]()
        var truncated = false
        while arguments.count < Int(argc) {
            guard index < bytes.count else { truncated = true; break }
            let end = bytes[index...].firstIndex(of: 0)
            let limit = min(end ?? bytes.count, index + maxArgumentBytes)
            arguments.append(decode(bytes[index..<limit]))
            if end == nil || limit < (end ?? limit) { truncated = true }
            index = (end ?? bytes.count) + 1
        }
        return .success(Parsed(
            executablePath: path, commandLine: ProcessDetails.CommandLine(arguments: arguments, truncated: truncated)))
    }

    /// Lossy: invalid UTF-8 becomes U+FFFD.
    private static func decode(_ slice: ArraySlice<UInt8>) -> String {
        String(decoding: slice, as: UTF8.self)
    }
}

/// Small identity-keyed LRU of loaded details. Holds command lines in memory
/// only; never logged. Most recently used is last.
public struct DetailCache: Sendable, Equatable {
    public static let defaultCapacity = 16

    public let capacity: Int
    private var entries: [ProcessDetails] = []

    public init(capacity: Int = DetailCache.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { entries.count }

    public mutating func insert(_ details: ProcessDetails) {
        entries.removeAll { $0.identity == details.identity }
        entries.append(details)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    /// Returns the entry and marks it most recently used.
    public mutating func lookup(_ identity: ProcessIdentity) -> ProcessDetails? {
        guard let i = entries.firstIndex(where: { $0.identity == identity }) else { return nil }
        let entry = entries.remove(at: i)
        entries.append(entry)
        return entry
    }
}

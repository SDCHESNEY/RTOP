/// The signals the monitor may send. Anything else is unrepresentable, which
/// is the allow-list. Numbers are the Darwin values (checked against the SDK
/// constants in the MonitorDarwin tests; this module does not import Darwin).
public enum ControlSignal: Sendable, Equatable, CaseIterable {
    case term, kill, int, hup, stop, cont

    public var number: Int32 {
        switch self {
        case .hup: 1
        case .int: 2
        case .kill: 9
        case .term: 15
        case .stop: 17
        case .cont: 19
        }
    }

    public var name: String {
        switch self {
        case .term: "SIGTERM"
        case .kill: "SIGKILL"
        case .int: "SIGINT"
        case .hup: "SIGHUP"
        case .stop: "SIGSTOP"
        case .cont: "SIGCONT"
        }
    }

    /// One line shown in the confirmation modal.
    public var explanation: String {
        switch self {
        case .term: "Asks the process to terminate. It may handle or ignore this."
        case .kill: "Destructive: the process is ended at once, with no chance to clean up."
        case .int: "Interrupt, as Ctrl-C would. The process may handle or ignore it."
        case .hup: "Hang-up. Many daemons reload their configuration on it."
        case .stop: "Suspends the process until it receives SIGCONT. It cannot be ignored."
        case .cont: "Resumes a stopped process."
        }
    }

    public var isDestructive: Bool { self == .kill }

    /// Next/previous signal for Right/Left in the modal, wrapping around.
    public func advanced(by step: Int) -> ControlSignal {
        let all = ControlSignal.allCases
        let i = all.firstIndex(of: self)!
        return all[((i + step) % all.count + all.count) % all.count]
    }
}

/// What the user confirmed. Captured when the modal opens; the controller
/// re-reads the live process and compares before delivering anything.
public struct SignalRequest: Sendable, Equatable {
    public var identity: ProcessIdentity
    public var name: String
    public var uid: UInt32?
    public var path: String?
    public var signal: ControlSignal
    /// Root-owned or under a system location: needs the second confirmation stage.
    public var isProtected: Bool

    public init(
        identity: ProcessIdentity, name: String, uid: UInt32?, path: String?,
        signal: ControlSignal = .term
    ) {
        self.identity = identity
        self.name = name
        self.uid = uid
        self.path = path
        self.signal = signal
        self.isProtected = CautionPolicy.isCaution(uid: uid, path: path)
    }
}

public struct SignalSent: Sendable, Equatable {
    public var pid: Int32
    public var signal: ControlSignal

    public init(pid: Int32, signal: ControlSignal) {
        self.pid = pid
        self.signal = signal
    }
}

public enum ControlError: Error, Sendable, Equatable {
    /// PID is zero, negative, or outside the native PID range.
    case invalidTarget
    /// PID 1 or the monitor itself.
    case protectedTarget
    case permissionDenied          // EPERM
    case processExited             // ESRCH
    /// The PID now belongs to a different process (start time differs).
    case identityChanged
    /// The start time could not be read, so the target cannot be verified.
    case identityUnavailable
    /// The target became root-owned or system-located since confirmation.
    case cautionChanged
    case osFailure(errno: Int32)
}

public protocol ProcessControlling: Sendable {
    /// Validates, re-reads the target's identity, and delivers one signal.
    /// Success means the kernel accepted the signal, not that the process exited.
    func send(_ request: SignalRequest) -> Result<SignalSent, ControlError>
}

public enum ProcessControlPolicy {
    /// Darwin's `PID_MAX`.
    public static let maxPID: Int32 = 99_999

    /// Pre-checks that need no OS access. Also used by the controller.
    public static func validate(pid: Int32, ownPID: Int32) -> ControlError? {
        if pid <= 0 || pid > maxPID { return .invalidTarget }
        if pid == 1 || pid == ownPID { return .protectedTarget }
        return nil
    }
}

/// Decides when a target needs the second confirmation stage.
public enum CautionPolicy {
    static let protectedTopLevelDirectories: Set<String> = ["System", "usr", "sbin"]

    /// Root-owned (or unknown owner), or an executable whose path has
    /// `/System`, `/usr`, or `/sbin` as its leading *component* (so `/usrlocal`
    /// and `/home/usr` do not match).
    public static func isCaution(uid: UInt32?, path: String?) -> Bool {
        guard let uid else { return true }
        if uid == 0 { return true }
        guard let path, path.hasPrefix("/") else { return false }
        guard let first = path.split(separator: "/", omittingEmptySubsequences: true).first else { return false }
        return protectedTopLevelDirectories.contains(String(first))
    }
}

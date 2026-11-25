import Darwin
import DarwinSupport
import Foundation
import MonitorCore

/// Everything the collector needs from the OS. The live implementation calls
/// the C boundary; tests substitute fakes to inject per-PID failures.
public protocol NativeProcessAPI {
    func listPIDs() throws -> [Int32]
    func bsdInfo(pid: Int32) throws -> ProcessBSD
    func taskInfo(pid: Int32) throws -> ProcessTask
    func path(pid: Int32) throws -> String
    func cpuTicks() throws -> [CPUTicks]
    func loadAverage() -> LoadAverage?
}

public struct LiveNativeProcessAPI: NativeProcessAPI {
    public init() {}

    public func listPIDs() throws -> [Int32] { try NativeProbe.listPIDs() }
    public func bsdInfo(pid: Int32) throws -> ProcessBSD { try NativeProbe.bsdInfo(pid: pid) }
    public func taskInfo(pid: Int32) throws -> ProcessTask { try NativeProbe.taskInfo(pid: pid) }
    public func path(pid: Int32) throws -> String { try NativeProbe.path(pid: pid) }

    public func cpuTicks() throws -> [CPUTicks] {
        try NativeProbe.cpuTicks().map { CPUTicks(user: $0.user, system: $0.system, idle: $0.idle, nice: $0.nice) }
    }

    public func loadAverage() -> LoadAverage? {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return nil }
        return LoadAverage(one: loads[0], five: loads[1], fifteen: loads[2])
    }
}

/// Maps a native failure to an availability reason.
func unavailableReason(for error: Error) -> UnavailableReason {
    guard let native = error as? NativeError else { return .collectionFailed }
    switch native.kind {
    case .errno:
        switch native.code {
        case EPERM, EACCES: return .permissionDenied
        case ESRCH: return .processExited
        default: return .collectionFailed
        }
    case .shortResult: return .malformed
    case .noMemory, .retryExhausted, .mach: return .collectionFailed
    }
}

/// Conservative mapping of the native `pbi_status` value. The numbers are the
/// BSD process states (SIDL=1, SRUN=2, SSLEEP=3, SSTOP=4, SZOMB=5); anything
/// else is `.unknown` rather than a guess.
func processStatus(nativeValue: UInt32) -> ProcessStatus {
    switch nativeValue {
    case 1: .idle
    case 2: .running
    case 3: .sleeping
    case 4: .stopped
    case 5: .zombie
    default: .unknown
    }
}

/// uid → user name, resolved on the collector thread (never on the render
/// path). Entries expire and the cache is size-capped, so it stays bounded.
/// A uid with no passwd entry shows its number rather than being hidden.
final class UserNameCache {
    private struct Entry {
        var name: String
        var expiresAt: UInt64
    }

    private let clock: any MonotonicClock
    private let lifetimeNanoseconds: UInt64
    private let maxEntries: Int
    private let lookup: (UInt32) -> String?
    private var entries: [UInt32: Entry] = [:]

    init(
        clock: any MonotonicClock,
        lifetimeNanoseconds: UInt64 = 60_000_000_000,
        maxEntries: Int = 1024,
        lookup: @escaping (UInt32) -> String? = UserNameCache.systemLookup
    ) {
        self.clock = clock
        self.lifetimeNanoseconds = lifetimeNanoseconds
        self.maxEntries = maxEntries
        self.lookup = lookup
    }

    func name(for uid: UInt32) -> String {
        let now = clock.nowNanoseconds()
        if let entry = entries[uid], entry.expiresAt > now { return entry.name }
        let name = lookup(uid) ?? String(uid)
        if entries.count >= maxEntries { entries.removeAll(keepingCapacity: true) }
        entries[uid] = Entry(name: name, expiresAt: now + lifetimeNanoseconds)
        return name
    }

    var count: Int { entries.count }

    /// Thread-safe `getpwuid_r` with a growing buffer.
    static func systemLookup(_ uid: UInt32) -> String? {
        var size = 1024
        while size <= 64 * 1024 {
            var buffer = [CChar](repeating: 0, count: size)
            var pwd = passwd()
            var result: UnsafeMutablePointer<passwd>?
            let rc = getpwuid_r(uid_t(uid), &pwd, &buffer, buffer.count, &result)
            if rc == ERANGE { size *= 2; continue }
            guard rc == 0, result != nil, let cName = pwd.pw_name else { return nil }
            return String(cString: cName)
        }
        return nil
    }
}

/// Builds snapshots from the native API. Not `Sendable`: it owns CPU baselines
/// and is used by one thread (the sampling worker).
public final class DarwinCollector: SystemCollector {
    private let api: any NativeProcessAPI
    private let clock: any MonotonicClock
    private let users: UserNameCache
    private var processCPU = ProcessCPUTracker()
    private var hostCPU = HostCPUTracker()

    public convenience init() {
        self.init(api: LiveNativeProcessAPI(), clock: SystemMonotonicClock())
    }

    public init(api: any NativeProcessAPI, clock: any MonotonicClock) {
        self.api = api
        self.clock = clock
        self.users = UserNameCache(clock: clock)
    }

    /// Builds one row, or nil if the process exited while being read. Any
    /// other per-PID failure yields a partial row plus the reasons (each
    /// distinct reason counted once per row). A process exiting mid-read is
    /// normal churn, so `.processExited` is never reported as a warning.
    private func summarize(pid: Int32) -> (ProcessSummary, Set<UnavailableReason>)? {
        var limited = Set<UnavailableReason>()

        var bsd: ProcessBSD?
        var bsdReason = UnavailableReason.collectionFailed
        do {
            bsd = try api.bsdInfo(pid: pid)
        } catch {
            bsdReason = unavailableReason(for: error)
            if bsdReason == .processExited { return nil }
            limited.insert(bsdReason)
        }

        // Without BSD info (typically EPERM for other users' processes) there is no
        // start time, so the identity is PID-only and no CPU baseline is kept.
        let identity = ProcessIdentity(
            pid: pid,
            start: bsd.map { ProcessStartTime(seconds: $0.startSeconds, microseconds: $0.startMicroseconds) }
        )

        var cpu: Availability<Double>
        var resident: Availability<UInt64>
        do {
            let task = try api.taskInfo(pid: pid)
            resident = .value(task.residentBytes)
            cpu = processCPU.observe(
                identity: identity,
                cpuNanoseconds: task.userTimeNanoseconds &+ task.systemTimeNanoseconds,
                atNanoseconds: clock.nowNanoseconds()
            )
        } catch {
            let reason = unavailableReason(for: error)
            if reason == .processExited { return nil }
            limited.insert(reason)
            resident = .unavailable(reason)
            cpu = .unavailable(reason)
        }

        let path: Availability<String>
        do {
            path = .value(try api.path(pid: pid))
        } catch {
            let reason = unavailableReason(for: error)
            if reason != .processExited { limited.insert(reason) }
            if reason == .processExited, bsd == nil { return nil }
            path = .unavailable(reason)
        }

        let name: String
        if let bsd, !bsd.name.isEmpty {
            name = bsd.name
        } else if let executable = path.value.map({ ($0 as NSString).lastPathComponent }), !executable.isEmpty {
            name = executable
        } else {
            name = "(unnamed)"
        }

        let row = ProcessSummary(
            identity: identity,
            parentPID: bsd.map { .value($0.ppid) } ?? .unavailable(bsdReason),
            name: name,
            uid: bsd.map { .value($0.uid) } ?? .unavailable(bsdReason),
            userName: bsd.map { .value(users.name(for: $0.uid)) } ?? .unavailable(bsdReason),
            cpuPercent: cpu,
            residentBytes: resident,
            status: bsd.map { processStatus(nativeValue: $0.status) } ?? .unknown,
            executablePath: path
        )
        return (row, limited)
    }

    public func collect() throws -> Snapshot {
        let pids = try api.listPIDs()

        var rows = [ProcessSummary]()
        rows.reserveCapacity(pids.count)
        var warningCounts: [UnavailableReason: Int] = [:]

        for pid in pids {
            guard let (row, reasons) = summarize(pid: pid) else { continue } // exited mid-read
            for reason in reasons { warningCounts[reason, default: 0] += 1 }
            rows.append(row)
        }
        processCPU.prune(keeping: Set(rows.map(\.identity)))

        let hostReading: Availability<CPUReading>
        do {
            hostReading = hostCPU.observe(try api.cpuTicks())
        } catch {
            hostReading = .unavailable(unavailableReason(for: error))
        }

        let warnings = UnavailableReason.allCases.compactMap { reason in
            warningCounts[reason].map { CollectionWarning(reason: reason, count: $0) }
        }
        return Snapshot(
            capturedAtNanoseconds: clock.nowNanoseconds(),
            processes: rows,
            cpu: hostReading,
            load: api.loadAverage().map { .value($0) } ?? .unavailable(.collectionFailed),
            warnings: warnings
        )
    }
}

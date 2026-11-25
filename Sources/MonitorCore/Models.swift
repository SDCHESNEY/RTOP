/// Why a value is not available. "Unavailable" is never rendered or stored as zero.
public enum UnavailableReason: Sendable, Equatable, Hashable, CaseIterable {
    case permissionDenied
    case processExited
    case unsupported
    case notYetSampled
    case malformed
    case collectionFailed
}

/// A value, or an explicit reason it could not be obtained.
public enum Availability<Value: Sendable & Equatable>: Sendable, Equatable {
    case value(Value)
    case unavailable(UnavailableReason)

    public var value: Value? {
        if case .value(let v) = self { return v }
        return nil
    }

    public var unavailableReason: UnavailableReason? {
        if case .unavailable(let r) = self { return r }
        return nil
    }

    public func map<T: Sendable & Equatable>(_ transform: (Value) -> T) -> Availability<T> {
        switch self {
        case .value(let v): .value(transform(v))
        case .unavailable(let r): .unavailable(r)
        }
    }
}

/// Process start time at native (microsecond) precision.
public struct ProcessStartTime: Sendable, Equatable, Hashable, Comparable {
    public var seconds: UInt64
    public var microseconds: UInt64

    public init(seconds: UInt64, microseconds: UInt64) {
        self.seconds = seconds
        self.microseconds = microseconds
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.seconds, lhs.microseconds) < (rhs.seconds, rhs.microseconds)
    }
}

/// PIDs are reused, so a process is identified by PID plus start time.
/// `start == nil` means the start time could not be read; such an identity
/// never matches another and cannot anchor a CPU baseline.
public struct ProcessIdentity: Sendable, Equatable, Hashable {
    public var pid: Int32
    public var start: ProcessStartTime?

    public init(pid: Int32, start: ProcessStartTime?) {
        self.pid = pid
        self.start = start
    }
}

/// Conservative process state. Anything not positively recognised is `.unknown`.
public enum ProcessStatus: Sendable, Equatable {
    case running, sleeping, idle, stopped, zombie, unknown
}

public struct ProcessSummary: Sendable, Equatable {
    public var identity: ProcessIdentity
    public var parentPID: Availability<Int32>
    public var name: String
    public var uid: Availability<UInt32>
    public var userName: Availability<String>
    /// Percent of one logical CPU (can exceed 100 for multithreaded processes).
    public var cpuPercent: Availability<Double>
    public var residentBytes: Availability<UInt64>
    public var status: ProcessStatus
    public var executablePath: Availability<String>

    public init(
        identity: ProcessIdentity,
        parentPID: Availability<Int32> = .unavailable(.collectionFailed),
        name: String,
        uid: Availability<UInt32> = .unavailable(.collectionFailed),
        userName: Availability<String> = .unavailable(.collectionFailed),
        cpuPercent: Availability<Double> = .unavailable(.notYetSampled),
        residentBytes: Availability<UInt64> = .unavailable(.collectionFailed),
        status: ProcessStatus = .unknown,
        executablePath: Availability<String> = .unavailable(.collectionFailed)
    ) {
        self.identity = identity
        self.parentPID = parentPID
        self.name = name
        self.uid = uid
        self.userName = userName
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
        self.status = status
        self.executablePath = executablePath
    }
}

public struct CPUReading: Sendable, Equatable {
    /// Whole-machine busy percentage, 0...100, from summed tick deltas.
    public var aggregatePercent: Double
    /// Per logical CPU, 0...100. Not classified as performance/efficiency.
    public var perCorePercent: [Double]

    public init(aggregatePercent: Double, perCorePercent: [Double]) {
        self.aggregatePercent = aggregatePercent
        self.perCorePercent = perCorePercent
    }
}

/// Raw page categories, kept separate (populated from Phase 2).
public struct MemoryReading: Sendable, Equatable {
    public var pageSizeBytes: UInt64
    public var freePages, activePages, inactivePages, wiredPages: UInt64
    public var compressorPages, purgeablePages, speculativePages: UInt64

    public init(
        pageSizeBytes: UInt64, freePages: UInt64, activePages: UInt64, inactivePages: UInt64,
        wiredPages: UInt64, compressorPages: UInt64, purgeablePages: UInt64, speculativePages: UInt64
    ) {
        self.pageSizeBytes = pageSizeBytes
        self.freePages = freePages
        self.activePages = activePages
        self.inactivePages = inactivePages
        self.wiredPages = wiredPages
        self.compressorPages = compressorPages
        self.purgeablePages = purgeablePages
        self.speculativePages = speculativePages
    }
}

public struct SwapReading: Sendable, Equatable {
    public var totalBytes, usedBytes, freeBytes: UInt64

    public init(totalBytes: UInt64, usedBytes: UInt64, freeBytes: UInt64) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.freeBytes = freeBytes
    }
}

/// Load averages are run-queue load, not CPU percentages.
public struct LoadAverage: Sendable, Equatable {
    public var one, five, fifteen: Double

    public init(one: Double, five: Double, fifteen: Double) {
        self.one = one
        self.five = five
        self.fifteen = fifteen
    }
}

/// Aggregated per-pass count of rows that were partially collected, by reason.
/// Bounded by the number of reasons, so a pass never produces a message flood.
public struct CollectionWarning: Sendable, Equatable {
    public var reason: UnavailableReason
    public var count: Int

    public init(reason: UnavailableReason, count: Int) {
        self.reason = reason
        self.count = count
    }
}

public struct Snapshot: Sendable, Equatable {
    /// Assigned by the sampling worker; strictly increasing.
    public var sequence: UInt64
    /// Monotonic capture time (nanoseconds), for elapsed-time arithmetic.
    public var capturedAtNanoseconds: UInt64
    public var processes: [ProcessSummary]
    public var cpu: Availability<CPUReading>
    public var load: Availability<LoadAverage>
    public var memory: Availability<MemoryReading>
    public var swap: Availability<SwapReading>
    public var warnings: [CollectionWarning]

    public init(
        sequence: UInt64 = 0,
        capturedAtNanoseconds: UInt64 = 0,
        processes: [ProcessSummary] = [],
        cpu: Availability<CPUReading> = .unavailable(.notYetSampled),
        load: Availability<LoadAverage> = .unavailable(.notYetSampled),
        memory: Availability<MemoryReading> = .unavailable(.unsupported),
        swap: Availability<SwapReading> = .unavailable(.unsupported),
        warnings: [CollectionWarning] = []
    ) {
        self.sequence = sequence
        self.capturedAtNanoseconds = capturedAtNanoseconds
        self.processes = processes
        self.cpu = cpu
        self.load = load
        self.memory = memory
        self.swap = swap
        self.warnings = warnings
    }
}

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

/// Raw page categories, kept separate. A category the OS did not provide is
/// `nil` (unavailable), never zero.
public struct MemoryReading: Sendable, Equatable {
    public var pageSizeBytes: UInt64
    public var freePages, activePages, inactivePages, wiredPages: UInt64?
    public var compressorPages, purgeablePages, speculativePages, fileBackedPages: UInt64?

    public init(
        pageSizeBytes: UInt64, freePages: UInt64? = nil, activePages: UInt64? = nil,
        inactivePages: UInt64? = nil, wiredPages: UInt64? = nil, compressorPages: UInt64? = nil,
        purgeablePages: UInt64? = nil, speculativePages: UInt64? = nil, fileBackedPages: UInt64? = nil
    ) {
        self.pageSizeBytes = pageSizeBytes
        self.freePages = freePages
        self.activePages = activePages
        self.inactivePages = inactivePages
        self.wiredPages = wiredPages
        self.compressorPages = compressorPages
        self.purgeablePages = purgeablePages
        self.speculativePages = speculativePages
        self.fileBackedPages = fileBackedPages
    }
}

/// Last memory-pressure state reported by the OS notification source.
/// `unknown` until the first notification: absence of events is not "normal".
public enum MemoryPressureState: Sendable, Equatable {
    case unknown, normal, warning, critical
}

public struct MemoryPressureReading: Sendable, Equatable {
    public var state: MemoryPressureState
    /// Monotonic time of the notification that set `state`; nil when never observed.
    public var observedAtNanoseconds: UInt64?

    public init(state: MemoryPressureState = .unknown, observedAtNanoseconds: UInt64? = nil) {
        self.state = state
        self.observedAtNanoseconds = observedAtNanoseconds
    }

    public static let unknown = MemoryPressureReading()
}

/// Core counts as reported by the OS. Performance-level counts do not prove
/// which per-core tick entries belong to which level, so they are reported
/// separately and per-core usage stays unclassified.
public struct CoreTopology: Sendable, Equatable {
    public struct Level: Sendable, Equatable {
        public var index: Int
        public var name: String?
        public var logicalCPUs: Int

        public init(index: Int, name: String?, logicalCPUs: Int) {
            self.index = index
            self.name = name
            self.logicalCPUs = logicalCPUs
        }
    }

    public var logicalCPUs: Int?
    public var physicalCPUs: Int?
    /// Empty on Intel and other hardware without performance levels.
    public var levels: [Level]

    public init(logicalCPUs: Int?, physicalCPUs: Int?, levels: [Level] = []) {
        self.logicalCPUs = logicalCPUs
        self.physicalCPUs = physicalCPUs
        self.levels = levels
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
    public var pressure: MemoryPressureReading
    public var physicalMemoryBytes: Availability<UInt64>
    public var uptimeSeconds: Availability<Double>
    public var topology: Availability<CoreTopology>
    public var warnings: [CollectionWarning]

    public init(
        sequence: UInt64 = 0,
        capturedAtNanoseconds: UInt64 = 0,
        processes: [ProcessSummary] = [],
        cpu: Availability<CPUReading> = .unavailable(.notYetSampled),
        load: Availability<LoadAverage> = .unavailable(.notYetSampled),
        memory: Availability<MemoryReading> = .unavailable(.unsupported),
        swap: Availability<SwapReading> = .unavailable(.unsupported),
        pressure: MemoryPressureReading = .unknown,
        physicalMemoryBytes: Availability<UInt64> = .unavailable(.unsupported),
        uptimeSeconds: Availability<Double> = .unavailable(.unsupported),
        topology: Availability<CoreTopology> = .unavailable(.unsupported),
        warnings: [CollectionWarning] = []
    ) {
        self.sequence = sequence
        self.capturedAtNanoseconds = capturedAtNanoseconds
        self.processes = processes
        self.cpu = cpu
        self.load = load
        self.memory = memory
        self.swap = swap
        self.pressure = pressure
        self.physicalMemoryBytes = physicalMemoryBytes
        self.uptimeSeconds = uptimeSeconds
        self.topology = topology
        self.warnings = warnings
    }
}

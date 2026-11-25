/// Cumulative per-CPU tick counters (32-bit, wrapping), as reported by the host.
public struct CPUTicks: Sendable, Equatable {
    public var user, system, idle, nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// Pure CPU arithmetic, kept free of FFI so it is testable on its own.
/// Units and conventions are documented in Documentation/Metrics.md.
public enum CPUMath {
    /// Percent of one logical CPU used between two cumulative CPU-time readings.
    /// Returns nil when the interval is not trustworthy: nonpositive elapsed
    /// time, or a counter that went backwards (reset or identity mix-up).
    public static func processPercent(
        previousCPUNanoseconds: UInt64, currentCPUNanoseconds: UInt64, elapsedNanoseconds: UInt64
    ) -> Double? {
        guard elapsedNanoseconds > 0, currentCPUNanoseconds >= previousCPUNanoseconds else { return nil }
        let delta = currentCPUNanoseconds - previousCPUNanoseconds
        return Double(delta) / Double(elapsedNanoseconds) * 100
    }

    /// Host busy percentage from summed tick deltas (not a mean of per-core
    /// percentages). Tick counters are 32-bit and wrap, so deltas use wrapping
    /// subtraction. Returns nil when the CPU count changed, either side is
    /// empty, or no ticks elapsed.
    public static func hostBusy(previous: [CPUTicks], current: [CPUTicks]) -> CPUReading? {
        guard !previous.isEmpty, previous.count == current.count else { return nil }

        var totalBusy: UInt64 = 0
        var totalAll: UInt64 = 0
        var perCore = [Double]()
        perCore.reserveCapacity(current.count)

        for (p, c) in zip(previous, current) {
            let user = UInt64(c.user &- p.user)
            let system = UInt64(c.system &- p.system)
            let nice = UInt64(c.nice &- p.nice)
            let idle = UInt64(c.idle &- p.idle)
            let busy = user + system + nice
            let all = busy + idle
            totalBusy += busy
            totalAll += all
            perCore.append(all == 0 ? 0 : Double(busy) / Double(all) * 100)
        }
        guard totalAll > 0 else { return nil }
        return CPUReading(aggregatePercent: Double(totalBusy) / Double(totalAll) * 100, perCorePercent: perCore)
    }
}

/// Keeps one CPU-time baseline per process identity.
public struct ProcessCPUTracker: Sendable {
    private struct Baseline: Sendable {
        var cpuNanoseconds: UInt64
        var atNanoseconds: UInt64
    }

    private var baselines: [ProcessIdentity: Baseline] = [:]

    public init() {}

    public var trackedCount: Int { baselines.count }

    /// Records a reading and returns the CPU percentage since the previous
    /// reading of the same identity. The first observation, an identity without
    /// a start time, or an invalid interval yields an unavailable value; the
    /// new reading always becomes the baseline so the next pass can succeed.
    public mutating func observe(
        identity: ProcessIdentity, cpuNanoseconds: UInt64, atNanoseconds: UInt64
    ) -> Availability<Double> {
        // Without a start time a PID reuse cannot be detected: never baseline it.
        guard identity.start != nil else { return .unavailable(.collectionFailed) }

        defer { baselines[identity] = Baseline(cpuNanoseconds: cpuNanoseconds, atNanoseconds: atNanoseconds) }
        guard let old = baselines[identity] else { return .unavailable(.notYetSampled) }
        guard atNanoseconds > old.atNanoseconds,
              let percent = CPUMath.processPercent(
                previousCPUNanoseconds: old.cpuNanoseconds,
                currentCPUNanoseconds: cpuNanoseconds,
                elapsedNanoseconds: atNanoseconds - old.atNanoseconds)
        else { return .unavailable(.notYetSampled) }
        return .value(percent)
    }

    /// Drops baselines for processes that are no longer present.
    public mutating func prune(keeping live: Set<ProcessIdentity>) {
        baselines = baselines.filter { live.contains($0.key) }
    }
}

/// Keeps the previous host tick counters.
public struct HostCPUTracker: Sendable {
    private var previous: [CPUTicks]?

    public init() {}

    public mutating func observe(_ current: [CPUTicks]) -> Availability<CPUReading> {
        defer { previous = current }
        guard let previous else { return .unavailable(.notYetSampled) }
        guard let reading = CPUMath.hostBusy(previous: previous, current: current) else {
            return .unavailable(.notYetSampled)
        }
        return .value(reading)
    }
}

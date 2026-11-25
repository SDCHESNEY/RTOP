import Foundation

/// Monotonic time source for elapsed-time arithmetic. Never used for display.
public protocol MonotonicClock: Sendable {
    func nowNanoseconds() -> UInt64
}

public struct SystemMonotonicClock: MonotonicClock {
    public init() {}
    public func nowNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}

/// Produces one snapshot per call. Implementations may keep mutable state
/// (CPU baselines), so they are *not* `Sendable`: the sampling worker creates
/// the collector on its own thread and never shares it.
public protocol SystemCollector {
    func collect() throws -> Snapshot
}

public struct CollectionFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Collector scripted from an array, for sampler and reducer tests.
/// Each call consumes the next step; the last step repeats once exhausted.
public final class FakeCollector: SystemCollector {
    public enum Step {
        case snapshot(Snapshot)
        case failure(CollectionFailure)
    }

    private let steps: [Step]
    private var index = 0
    /// Optional hook run at the start of every call (used to simulate slowness).
    private let onCollect: (@Sendable () -> Void)?

    public init(steps: [Step], onCollect: (@Sendable () -> Void)? = nil) {
        precondition(!steps.isEmpty, "FakeCollector needs at least one step")
        self.steps = steps
        self.onCollect = onCollect
    }

    public func collect() throws -> Snapshot {
        onCollect?()
        let step = steps[min(index, steps.count - 1)]
        index += 1
        switch step {
        case .snapshot(let s): return s
        case .failure(let f): throw f
        }
    }
}

/// Settable clock for deterministic tests.
public final class ManualClock: MonotonicClock, @unchecked Sendable { // all access under `lock`
    private let lock = NSLock()
    private var now: UInt64

    public init(start: UInt64 = 0) { now = start }

    public func nowNanoseconds() -> UInt64 {
        lock.withLock { now }
    }

    public func advance(byNanoseconds delta: UInt64) {
        lock.withLock { now += delta }
    }
}

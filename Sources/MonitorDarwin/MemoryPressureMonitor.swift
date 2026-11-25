import Foundation
import Dispatch
import MonitorCore

/// Maps a dispatch memory-pressure event mask to a state. The most severe bit wins.
func memoryPressureState(for event: DispatchSource.MemoryPressureEvent) -> MemoryPressureState? {
    if event.contains(.critical) { return .critical }
    if event.contains(.warning) { return .warning }
    if event.contains(.normal) { return .normal }
    return nil
}

/// Records the last memory-pressure notification delivered by the OS.
///
/// The state is `unknown` until the first notification: the source reports
/// transitions, not the current level, and a quiet source does not prove the
/// system is under no pressure. Pressure is never derived from free memory.
///
/// `@unchecked Sendable`: `reading` is only touched under `lock`; the dispatch
/// source is created once in `init` and cancelled in `deinit`.
public final class MemoryPressureMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var reading = MemoryPressureReading.unknown
    private let source: any DispatchSourceMemoryPressure

    public init(clock: any MonotonicClock = SystemMonotonicClock()) {
        let queue = DispatchQueue(label: "rtop.memory-pressure")
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, let state = memoryPressureState(for: self.source.data) else { return }
            self.record(state, at: clock.nowNanoseconds())
        }
        source.activate()
    }

    deinit { source.cancel() }

    func record(_ state: MemoryPressureState, at nanoseconds: UInt64) {
        lock.withLock { reading = MemoryPressureReading(state: state, observedAtNanoseconds: nanoseconds) }
    }

    public var current: MemoryPressureReading {
        lock.withLock { reading }
    }
}

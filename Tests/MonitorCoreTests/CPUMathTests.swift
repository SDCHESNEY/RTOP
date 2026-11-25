import Testing
@testable import MonitorCore

@Suite struct CPUMathTests {
    @Test func processPercentIsShareOfOneCPU() {
        #expect(CPUMath.processPercent(previousCPUNanoseconds: 0, currentCPUNanoseconds: 500_000_000,
                                       elapsedNanoseconds: 1_000_000_000) == 50)
        // Multithreaded work can exceed 100%.
        #expect(CPUMath.processPercent(previousCPUNanoseconds: 0, currentCPUNanoseconds: 2_000_000_000,
                                       elapsedNanoseconds: 1_000_000_000) == 200)
    }

    @Test func zeroOrNegativeElapsedIsRejected() {
        #expect(CPUMath.processPercent(previousCPUNanoseconds: 0, currentCPUNanoseconds: 10, elapsedNanoseconds: 0) == nil)
    }

    @Test func counterResetIsRejected() {
        #expect(CPUMath.processPercent(previousCPUNanoseconds: 100, currentCPUNanoseconds: 50, elapsedNanoseconds: 1000) == nil)
    }

    @Test func extremeValuesDoNotOverflow() {
        let p = CPUMath.processPercent(previousCPUNanoseconds: 0, currentCPUNanoseconds: UInt64.max, elapsedNanoseconds: 1)
        #expect(p != nil)
        #expect(p?.isFinite == true)
    }

    @Test func hostBusyUsesSummedDeltasNotMeanOfCores() {
        // Core A: 100 ticks, all busy. Core B: 300 ticks, all idle.
        let prev = [CPUTicks(user: 0, system: 0, idle: 0, nice: 0), CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let cur = [CPUTicks(user: 60, system: 40, idle: 0, nice: 0), CPUTicks(user: 0, system: 0, idle: 300, nice: 0)]
        let r = CPUMath.hostBusy(previous: prev, current: cur)
        #expect(r?.aggregatePercent == 25) // a mean of per-core percentages would give 50
        #expect(r?.perCorePercent == [100, 0])
    }

    @Test func niceCountsAsBusy() {
        let r = CPUMath.hostBusy(previous: [CPUTicks(user: 0, system: 0, idle: 0, nice: 0)],
                                 current: [CPUTicks(user: 0, system: 0, idle: 50, nice: 50)])
        #expect(r?.aggregatePercent == 50)
    }

    @Test func tickCounterWraparoundIsHandled() {
        let prev = [CPUTicks(user: UInt32.max - 4, system: 0, idle: 100, nice: 0)]
        let cur = [CPUTicks(user: 5, system: 0, idle: 110, nice: 0)] // user advanced by 10 across the wrap
        let r = CPUMath.hostBusy(previous: prev, current: cur)
        #expect(r?.aggregatePercent == 50)
    }

    @Test func cpuCountChangeInvalidatesTheInterval() {
        let one = [CPUTicks(user: 1, system: 1, idle: 1, nice: 1)]
        #expect(CPUMath.hostBusy(previous: one, current: one + one) == nil)
        #expect(CPUMath.hostBusy(previous: [], current: []) == nil)
    }

    @Test func noElapsedTicksIsRejected() {
        let t = [CPUTicks(user: 1, system: 1, idle: 1, nice: 1)]
        #expect(CPUMath.hostBusy(previous: t, current: t) == nil)
    }
}

@Suite struct CPUTrackerTests {
    @Test func firstObservationIsNotYetSampledThenValueAppears() {
        var tracker = ProcessCPUTracker()
        let id = Fixtures.identity(10)
        #expect(tracker.observe(identity: id, cpuNanoseconds: 1_000, atNanoseconds: 0) == .unavailable(.notYetSampled))
        #expect(tracker.observe(identity: id, cpuNanoseconds: 501_000, atNanoseconds: 1_000_000) == .value(50))
    }

    @Test func newStartTimeGetsItsOwnBaseline() {
        var tracker = ProcessCPUTracker()
        _ = tracker.observe(identity: Fixtures.identity(10, start: 1), cpuNanoseconds: 9_000_000_000, atNanoseconds: 0)
        // PID reused by a new process with a tiny CPU counter: must not look like a reset-to-negative.
        let r = tracker.observe(identity: Fixtures.identity(10, start: 2), cpuNanoseconds: 5, atNanoseconds: 1_000)
        #expect(r == .unavailable(.notYetSampled))
    }

    @Test func identityWithoutStartIsNeverBaselined() {
        var tracker = ProcessCPUTracker()
        let id = ProcessIdentity(pid: 10, start: nil)
        #expect(tracker.observe(identity: id, cpuNanoseconds: 1, atNanoseconds: 0) == .unavailable(.collectionFailed))
        #expect(tracker.observe(identity: id, cpuNanoseconds: 2, atNanoseconds: 10) == .unavailable(.collectionFailed))
        #expect(tracker.trackedCount == 0)
    }

    @Test func counterResetAndZeroElapsedInvalidateButRebaseline() {
        var tracker = ProcessCPUTracker()
        let id = Fixtures.identity(10)
        _ = tracker.observe(identity: id, cpuNanoseconds: 1_000, atNanoseconds: 0)
        #expect(tracker.observe(identity: id, cpuNanoseconds: 10, atNanoseconds: 100) == .unavailable(.notYetSampled))
        #expect(tracker.observe(identity: id, cpuNanoseconds: 10, atNanoseconds: 100) == .unavailable(.notYetSampled)) // zero elapsed
        #expect(tracker.observe(identity: id, cpuNanoseconds: 60, atNanoseconds: 200) == .value(50))
    }

    @Test func pruneDropsExitedProcesses() {
        var tracker = ProcessCPUTracker()
        _ = tracker.observe(identity: Fixtures.identity(1), cpuNanoseconds: 0, atNanoseconds: 0)
        _ = tracker.observe(identity: Fixtures.identity(2), cpuNanoseconds: 0, atNanoseconds: 0)
        tracker.prune(keeping: [Fixtures.identity(2)])
        #expect(tracker.trackedCount == 1)
    }

    @Test func hostTrackerNeedsTwoSamples() {
        var host = HostCPUTracker()
        let a = [CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let b = [CPUTicks(user: 10, system: 0, idle: 10, nice: 0)]
        #expect(host.observe(a) == .unavailable(.notYetSampled))
        #expect(host.observe(b).value?.aggregatePercent == 50)
    }
}

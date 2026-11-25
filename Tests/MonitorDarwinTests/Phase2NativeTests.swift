import Darwin
import Dispatch
import Foundation
import MonitorCore
import Testing
@testable import MonitorDarwin

@Suite struct MemoryPressureMappingTests {
    @Test func mostSevereBitWins() {
        #expect(memoryPressureState(for: [.normal]) == .normal)
        #expect(memoryPressureState(for: [.warning]) == .warning)
        #expect(memoryPressureState(for: [.normal, .warning]) == .warning)
        #expect(memoryPressureState(for: [.warning, .critical]) == .critical)
        #expect(memoryPressureState(for: []) == nil)
    }

    @Test func monitorStartsUnknownAndRecordsProvenance() {
        let monitor = MemoryPressureMonitor()
        #expect(monitor.current == .unknown) // no notification is not "normal"
        monitor.record(.warning, at: 42)
        #expect(monitor.current == MemoryPressureReading(state: .warning, observedAtNanoseconds: 42))
    }
}

@Suite struct Phase2NativeTests {
    @Test func liveMemoryReadingHasConsistentCategories() throws {
        let memory = try NativeProbe.memory()
        #expect(memory.pageSizeBytes == 4096 || memory.pageSizeBytes == 16384)
        #expect(memory.wiredPages != nil && memory.activePages != nil && memory.compressorPages != nil)
        let used = try #require(MemoryMath.approximateUsedBytes(memory))
        let total = try NativeProbe.physicalMemoryBytes()
        #expect(used > 0 && used <= total)
    }

    @Test func liveSwapAndBootTimeAreSane() throws {
        let swap = try NativeProbe.swap()
        #expect(swap.usedBytes <= swap.totalBytes)
        let boot = try NativeProbe.bootTime()
        let uptime = MemoryMath.uptimeSeconds(bootSeconds: boot.seconds, bootMicroseconds: boot.microseconds,
                                              now: Date().timeIntervalSince1970)
        #expect(uptime > 0)
    }

    @Test func liveTopologyReportsCountsOnly() {
        let topology = NativeProbe.topology()
        #expect((topology.logicalCPUs ?? 0) > 0)
        for level in topology.levels { #expect(level.logicalCPUs > 0) }
        if !topology.levels.isEmpty {
            #expect(topology.levels.map(\.logicalCPUs).reduce(0, +) <= topology.logicalCPUs ?? 0)
        }
    }

    @Test func liveCollectorFillsOverviewFields() throws {
        let snapshot = try DarwinCollector().collect()
        #expect(snapshot.memory.value != nil)
        #expect(snapshot.swap.value != nil)
        #expect(snapshot.physicalMemoryBytes.value != nil)
        #expect(snapshot.uptimeSeconds.value != nil)
        #expect(snapshot.topology.value != nil)
    }
}

/// API that implements only the process basics: new metrics must report unsupported, not zero.
private final class BareAPI: NativeProcessAPI {
    func listPIDs() throws -> [Int32] { [] }
    func bsdInfo(pid: Int32) throws -> ProcessBSD { throw NativeError(kind: .errno, code: ESRCH, operation: "x") }
    func taskInfo(pid: Int32) throws -> ProcessTask { throw NativeError(kind: .errno, code: ESRCH, operation: "x") }
    func path(pid: Int32) throws -> String { throw NativeError(kind: .errno, code: ESRCH, operation: "x") }
    func cpuTicks() throws -> [CPUTicks] { [] }
    func loadAverage() -> LoadAverage? { nil }
}

@Suite struct UnsupportedMetricsTests {
    @Test func missingMetricsAreUnavailableNeverZero() throws {
        let snapshot = try DarwinCollector(api: BareAPI(), clock: ManualClock()).collect()
        #expect(snapshot.memory == .unavailable(.unsupported))
        #expect(snapshot.swap == .unavailable(.unsupported))
        #expect(snapshot.uptimeSeconds == .unavailable(.unsupported))
        #expect(snapshot.physicalMemoryBytes == .unavailable(.unsupported))
        #expect(snapshot.topology == .unavailable(.unsupported))
        #expect(snapshot.pressure == .unknown)
    }
}

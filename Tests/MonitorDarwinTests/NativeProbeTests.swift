import Darwin
import Foundation
import Testing
@testable import MonitorDarwin

@Suite struct NativeProbeTests {
    @Test func enumerationContainsSelfAndLaunchd() throws {
        let pids = try NativeProbe.listPIDs()
        #expect(pids.contains(getpid()))
        #expect(pids.contains(1))
        #expect(!pids.contains(0))
    }

    @Test func ownBSDInfoIsConsistent() throws {
        let info = try NativeProbe.bsdInfo(pid: getpid())
        #expect(info.pid == getpid())
        #expect(info.ppid == getppid())
        #expect(info.uid == getuid())
        #expect(info.startSeconds > 0)
        #expect(!info.name.isEmpty)
    }

    @Test func ownTaskInfoIsPlausible() throws {
        let t = try NativeProbe.taskInfo(pid: getpid())
        #expect(t.residentBytes > 0)
        #expect(t.virtualBytes >= t.residentBytes)
        #expect(t.threadCount >= 1)
    }

    @Test func ownPathIsAbsolute() throws {
        #expect(try NativeProbe.path(pid: getpid()).hasPrefix("/"))
    }

    @Test func nonexistentPIDFailsWithoutCrashing() {
        // PID_MAX on macOS is 99999; this PID cannot exist.
        #expect(throws: NativeError.self) { try NativeProbe.bsdInfo(pid: 2_000_000) }
        #expect(throws: NativeError.self) { try NativeProbe.taskInfo(pid: 2_000_000) }
        #expect(throws: NativeError.self) { try NativeProbe.path(pid: 2_000_000) }
    }

    @Test func cpuCountMatchesFoundation() throws {
        let ticks = try NativeProbe.cpuTicks()
        #expect(ticks.count == ProcessInfo.processInfo.processorCount)
    }

    @Test func memoryAgreesWithFoundation() throws {
        let r = try NativeProbe.run()
        #expect(r.physicalMemoryBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(r.pageSizeBytes == UInt64(getpagesize()))
        #expect(r.processCount > 1)
    }

    /// Mach buffers are released on every call: repeated sampling must not grow
    /// the process resident size. A loose bound avoids flakiness; Instruments Leaks
    /// is the authoritative check (see SDKInteropReport.md).
    @Test func repeatedSamplingDoesNotGrowFootprint() throws {
        func footprint() throws -> UInt64 { try NativeProbe.taskInfo(pid: getpid()).residentBytes }
        for _ in 0..<200 { _ = try NativeProbe.run() } // warm-up
        let before = try footprint()
        for _ in 0..<1000 { _ = try NativeProbe.run() }
        let growth = Int64(try footprint()) - Int64(before)
        #expect(growth < 8 * 1024 * 1024, "footprint grew by \(growth) bytes")
    }
}

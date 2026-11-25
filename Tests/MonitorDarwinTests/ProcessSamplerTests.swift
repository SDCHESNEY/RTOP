import Darwin
import Foundation
import MonitorCore
import Testing
@testable import MonitorDarwin

/// Scripted native API for failure injection. Used from one thread only.
private final class FakeAPI: NativeProcessAPI {
    var pids: [Int32] = []
    var bsd: [Int32: Result<ProcessBSD, NativeError>] = [:]
    var task: [Int32: Result<ProcessTask, NativeError>] = [:]
    var paths: [Int32: Result<String, NativeError>] = [:]
    var ticks: Result<[CPUTicks], NativeError> = .success([])
    var listError: NativeError?

    static func errno(_ code: Int32) -> NativeError {
        NativeError(kind: .errno, code: code, operation: "fake")
    }

    func listPIDs() throws -> [Int32] {
        if let listError { throw listError }
        return pids
    }
    func bsdInfo(pid: Int32) throws -> ProcessBSD { try (bsd[pid] ?? .failure(Self.errno(ESRCH))).get() }
    func taskInfo(pid: Int32) throws -> ProcessTask { try (task[pid] ?? .failure(Self.errno(ESRCH))).get() }
    func path(pid: Int32) throws -> String { try (paths[pid] ?? .failure(Self.errno(ESRCH))).get() }
    func cpuTicks() throws -> [CPUTicks] { try ticks.get() }
    func loadAverage() -> LoadAverage? { LoadAverage(one: 1, five: 2, fifteen: 3) }

    func addHealthy(_ pid: Int32, start: UInt64 = 100, cpuNs: UInt64 = 0, uid: UInt32 = 501) {
        pids.append(pid)
        bsd[pid] = .success(ProcessBSD(pid: pid, ppid: 1, uid: uid, status: 3, startSeconds: start,
                                       startMicroseconds: 7, name: "p\(pid)"))
        task[pid] = .success(ProcessTask(residentBytes: 4096, virtualBytes: 8192, userTimeNanoseconds: cpuNs,
                                         systemTimeNanoseconds: 0, threadCount: 1))
        paths[pid] = .success("/bin/p\(pid)")
    }
}

@Suite struct ProcessSamplerFailureTests {
    private func collector(_ api: FakeAPI, clock: ManualClock = ManualClock()) -> DarwinCollector {
        DarwinCollector(api: api, clock: clock)
    }

    @Test func exitedProcessIsSilentlyDropped() throws {
        let api = FakeAPI()
        api.addHealthy(10)
        api.pids.append(20) // enumerated, but exits before any read: ESRCH everywhere
        let snap = try collector(api).collect()
        #expect(snap.processes.map(\.identity.pid) == [10])
        #expect(snap.warnings.isEmpty)
    }

    @Test func processExitingBetweenBSDAndTaskReadIsDropped() throws {
        let api = FakeAPI()
        api.addHealthy(10)
        api.task[10] = .failure(FakeAPI.errno(ESRCH))
        let snap = try collector(api).collect()
        #expect(snap.processes.isEmpty)
        #expect(snap.warnings.isEmpty)
    }

    @Test func restrictedTaskInfoYieldsPartialRowNotFailedRefresh() throws {
        let api = FakeAPI()
        api.addHealthy(10)
        api.addHealthy(30)
        api.task[30] = .failure(FakeAPI.errno(EPERM))
        let snap = try collector(api).collect()
        #expect(snap.processes.count == 2)
        let restricted = try #require(snap.processes.first { $0.identity.pid == 30 })
        #expect(restricted.cpuPercent == .unavailable(.permissionDenied))
        #expect(restricted.residentBytes == .unavailable(.permissionDenied))
        #expect(restricted.name == "p30") // the readable fields survive
        #expect(snap.warnings == [CollectionWarning(reason: .permissionDenied, count: 1)])
    }

    @Test func unreadablePathIsPartialAndWarningsAreAggregated() throws {
        let api = FakeAPI()
        for pid in Int32(10)..<60 {
            api.addHealthy(pid)
            api.paths[pid] = .failure(FakeAPI.errno(EPERM))
        }
        let snap = try collector(api).collect()
        #expect(snap.processes.count == 50)
        #expect(snap.processes.allSatisfy { $0.executablePath == .unavailable(.permissionDenied) })
        #expect(snap.warnings == [CollectionWarning(reason: .permissionDenied, count: 50)]) // one entry, not 50
    }

    @Test func unreadableBSDInfoYieldsPartialRowWithPIDOnlyIdentity() throws {
        let api = FakeAPI()
        api.addHealthy(10)
        api.addHealthy(20)
        api.bsd[20] = .failure(FakeAPI.errno(EPERM))
        let snap = try collector(api).collect()
        #expect(snap.processes.map(\.identity.pid) == [10, 20])
        let partial = snap.processes[1]
        #expect(partial.identity.start == nil)
        #expect(partial.name == "p20") // falls back to the executable name from the path
        #expect(partial.parentPID == .unavailable(.permissionDenied))
        #expect(partial.userName == .unavailable(.permissionDenied))
        #expect(partial.status == .unknown)
        #expect(partial.residentBytes == .value(4096)) // still readable
        #expect(partial.cpuPercent == .unavailable(.collectionFailed)) // no start time: no baseline
        #expect(snap.warnings == [CollectionWarning(reason: .permissionDenied, count: 1)])
    }

    @Test func unreadableBSDAndTaskAndPathCountsOneWarningPerReasonPerRow() throws {
        let api = FakeAPI()
        api.addHealthy(10)
        api.bsd[10] = .failure(FakeAPI.errno(EPERM))
        api.task[10] = .failure(FakeAPI.errno(EPERM))
        api.paths[10] = .failure(FakeAPI.errno(EPERM))
        let snap = try collector(api).collect()
        #expect(snap.processes.count == 1)
        #expect(snap.processes[0].name == "(unnamed)")
        #expect(snap.warnings == [CollectionWarning(reason: .permissionDenied, count: 1)])
    }

    @Test func otherBSDFailureIsPartialWithCollectionFailedReason() throws {
        let api = FakeAPI()
        api.addHealthy(10)
        api.bsd[10] = .failure(FakeAPI.errno(EIO))
        let snap = try collector(api).collect()
        #expect(snap.processes.count == 1)
        #expect(snap.warnings == [CollectionWarning(reason: .collectionFailed, count: 1)])
    }

    @Test func shortNativeResultIsMalformed() throws {
        let api = FakeAPI()
        api.addHealthy(10)
        api.task[10] = .failure(NativeError(kind: .shortResult, code: 0, operation: "fake"))
        let snap = try collector(api).collect()
        #expect(snap.processes.first?.residentBytes == .unavailable(.malformed))
    }

    @Test func enumerationFailureIsAThrownCollectionFailure() {
        let api = FakeAPI()
        api.listError = FakeAPI.errno(EPERM)
        #expect(throws: NativeError.self) { try collector(api).collect() }
    }

    @Test func hostCPUFailureDoesNotFailTheSnapshot() throws {
        let api = FakeAPI()
        api.addHealthy(10)
        api.ticks = .failure(NativeError(kind: .mach, code: 5, operation: "host_processor_info"))
        let snap = try collector(api).collect()
        #expect(snap.cpu == .unavailable(.collectionFailed))
        #expect(snap.processes.count == 1)
    }

    @Test func unknownNativeStatusIsUnknown() throws {
        let api = FakeAPI()
        api.addHealthy(10)
        api.bsd[10] = .success(ProcessBSD(pid: 10, ppid: 1, uid: 0, status: 99, startSeconds: 1,
                                          startMicroseconds: 1, name: ""))
        let row = try #require(try collector(api).collect().processes.first)
        #expect(row.status == .unknown)
        #expect(row.name == "p10") // empty BSD name falls back to the executable name
    }

    @Test func statusMappingIsConservative() {
        #expect(processStatus(nativeValue: 1) == .idle)
        #expect(processStatus(nativeValue: 2) == .running)
        #expect(processStatus(nativeValue: 3) == .sleeping)
        #expect(processStatus(nativeValue: 4) == .stopped)
        #expect(processStatus(nativeValue: 5) == .zombie)
        #expect(processStatus(nativeValue: 0) == .unknown)
        #expect(processStatus(nativeValue: 6) == .unknown)
    }
}

@Suite struct ProcessSamplerCPUTests {
    @Test func cpuIsUnavailableUntilASecondValidMeasurement() throws {
        let api = FakeAPI()
        api.addHealthy(10, cpuNs: 1_000_000_000)
        let clock = ManualClock(start: 5_000_000_000)
        let collector = DarwinCollector(api: api, clock: clock)

        let first = try collector.collect()
        #expect(first.processes[0].cpuPercent == .unavailable(.notYetSampled))
        #expect(first.cpu == .unavailable(.notYetSampled))

        clock.advance(byNanoseconds: 1_000_000_000)
        api.task[10] = .success(ProcessTask(residentBytes: 4096, virtualBytes: 8192,
                                            userTimeNanoseconds: 1_500_000_000, systemTimeNanoseconds: 0, threadCount: 1))
        let second = try collector.collect()
        let percent = try #require(second.processes[0].cpuPercent.value)
        #expect(abs(percent - 50) < 0.001)
    }

    @Test func reusedPIDStartsANewBaseline() throws {
        let api = FakeAPI()
        api.addHealthy(10, start: 100, cpuNs: 9_000_000_000)
        let clock = ManualClock(start: 1)
        let collector = DarwinCollector(api: api, clock: clock)
        _ = try collector.collect()

        clock.advance(byNanoseconds: 1_000_000_000)
        api.pids = []
        api.addHealthy(10, start: 200, cpuNs: 10) // same PID, new process
        let snap = try collector.collect()
        #expect(snap.processes[0].cpuPercent == .unavailable(.notYetSampled))
    }

    @Test func hostCPUAppearsOnTheSecondPass() throws {
        let api = FakeAPI()
        api.addHealthy(10)
        api.ticks = .success([CPUTicks(user: 0, system: 0, idle: 0, nice: 0)])
        let collector = DarwinCollector(api: api, clock: ManualClock())
        _ = try collector.collect()
        api.ticks = .success([CPUTicks(user: 10, system: 10, idle: 20, nice: 0)])
        #expect(try collector.collect().cpu.value?.aggregatePercent == 50)
    }

    @Test func baselinesForExitedProcessesArePruned() throws {
        let api = FakeAPI()
        api.addHealthy(10, cpuNs: 1)
        let clock = ManualClock(start: 1)
        let collector = DarwinCollector(api: api, clock: clock)
        _ = try collector.collect()
        api.pids = []
        _ = try collector.collect()
        // Same identity returns (it never really would): it must be treated as new.
        api.addHealthy(10, cpuNs: 1)
        clock.advance(byNanoseconds: 10)
        #expect(try collector.collect().processes[0].cpuPercent == .unavailable(.notYetSampled))
    }
}

@Suite struct UserNameCacheTests {
    private final class LookupLog {
        var uids: [UInt32] = []
    }

    @Test func resolvesOncePerLifetimeThenExpires() {
        let clock = ManualClock()
        let log = LookupLog()
        let cache = UserNameCache(clock: clock, lifetimeNanoseconds: 1000) { uid in
            log.uids.append(uid)
            return "user\(uid)"
        }
        #expect(cache.name(for: 5) == "user5")
        #expect(cache.name(for: 5) == "user5")
        #expect(log.uids.count == 1)
        clock.advance(byNanoseconds: 1001)
        _ = cache.name(for: 5)
        #expect(log.uids.count == 2)
    }

    @Test func unresolvableUIDShowsItsNumber() {
        let cache = UserNameCache(clock: ManualClock()) { _ in nil }
        #expect(cache.name(for: 4242) == "4242")
    }

    @Test func cacheIsBounded() {
        let cache = UserNameCache(clock: ManualClock(), maxEntries: 8) { "u\($0)" }
        for uid in 0..<100 { _ = cache.name(for: UInt32(uid)) }
        #expect(cache.count <= 8)
    }

    @Test func systemLookupResolvesCurrentUser() {
        #expect(UserNameCache.systemLookup(UInt32(getuid())) != nil)
        #expect(UserNameCache.systemLookup(0) == "root")
    }
}

@Suite struct ProcessSamplerLiveTests {
    @Test func liveSnapshotContainsSelfWithRealFields() throws {
        let collector = DarwinCollector()
        let snap = try collector.collect()
        let me = try #require(snap.processes.first { $0.identity.pid == getpid() })
        #expect(me.parentPID == .value(getppid()))
        #expect(me.uid == .value(getuid()))
        #expect(me.userName.value?.isEmpty == false)
        #expect((me.residentBytes.value ?? 0) > 0)
        #expect(me.executablePath.value?.hasPrefix("/") == true)
        #expect(me.identity.start != nil)
        #expect(snap.processes.contains { $0.identity.pid == 1 })
        #expect(snap.load.value != nil)
        #expect(Set(snap.processes.map(\.identity)).count == snap.processes.count)
    }

    @Test func unprivilegedEnumerationYieldsMostProcessesWithoutFailing() throws {
        let snap = try DarwinCollector().collect()
        let pids = try NativeProbe.listPIDs()
        // Allow for churn between the two enumerations, but a silent mass drop would be a bug.
        #expect(Double(snap.processes.count) > Double(pids.count) * 0.8,
                "\(snap.processes.count) rows from \(pids.count) pids")
    }

    @Test func selfCPUBecomesAvailableOnSecondPass() throws {
        let collector = DarwinCollector()
        let first = try collector.collect()
        #expect(first.processes.first { $0.identity.pid == getpid() }?.cpuPercent == .unavailable(.notYetSampled))
        // Burn a little CPU so the delta is measurable, then sample again.
        var x = 0.0
        let end = Date().addingTimeInterval(0.15)
        while Date() < end { x += sin(x) + 1 }
        #expect(x.isFinite)
        let second = try collector.collect()
        let cpu = try #require(second.processes.first { $0.identity.pid == getpid() }?.cpuPercent.value)
        #expect(cpu >= 0)
        #expect(cpu < 100 * Double(ProcessInfo.processInfo.processorCount) + 1)
        #expect(second.cpu.value != nil)
    }

    @Test func ownedChildIsObservedAndExitIsHandled() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } } // only a process this test spawned

        let collector = DarwinCollector()
        let snap = try collector.collect()
        let row = try #require(snap.processes.first { $0.identity.pid == child.processIdentifier })
        #expect(row.parentPID == .value(getpid()))
        #expect(row.name == "sleep")
        #expect(row.executablePath == .value("/bin/sleep"))

        child.terminate()
        child.waitUntilExit()
        let after = try collector.collect()
        #expect(!after.processes.contains { $0.identity == row.identity })
    }
}

import Darwin
import Foundation
import MonitorCore
import Testing
@testable import MonitorDarwin

private struct DetailsAPI: NativeProcessAPI {
    var bsd: Result<ProcessBSD, NativeError>
    var task: Result<ProcessTask, NativeError> = .success(
        ProcessTask(residentBytes: 1, virtualBytes: 2048, userTimeNanoseconds: 0, systemTimeNanoseconds: 0, threadCount: 4))
    var args: Result<[UInt8], NativeError>

    func listPIDs() throws -> [Int32] { [] }
    func bsdInfo(pid: Int32) throws -> ProcessBSD { try bsd.get() }
    func taskInfo(pid: Int32) throws -> ProcessTask { try task.get() }
    func path(pid: Int32) throws -> String { "/bin/x" }
    func cpuTicks() throws -> [CPUTicks] { [] }
    func loadAverage() -> LoadAverage? { nil }
    func procArgs(pid: Int32) throws -> [UInt8] { try args.get() }

    static func errno(_ code: Int32) -> NativeError { NativeError(kind: .errno, code: code, operation: "fake") }
}

private func bsd(start: UInt64 = 100) -> ProcessBSD {
    ProcessBSD(pid: 9, ppid: 1, uid: 501, status: 3, startSeconds: start, startMicroseconds: 7, name: "x")
}

private let identity = ProcessIdentity(pid: 9, start: ProcessStartTime(seconds: 100, microseconds: 7))

private func argsBytes(_ args: [String]) -> [UInt8] {
    var bytes = withUnsafeBytes(of: Int32(args.count)) { Array($0) }
    bytes += Array("/bin/x".utf8) + [0, 0]
    for a in args { bytes += Array(a.utf8) + [0] }
    return bytes + Array("SECRET=1".utf8) + [0]
}

@Suite struct DarwinDetailsTests {
    private func collector(_ api: DetailsAPI) -> DarwinCollector { DarwinCollector(api: api, clock: ManualClock()) }

    @Test func loadsCommandLineThreadsAndVirtualSize() {
        let d = collector(DetailsAPI(bsd: .success(bsd()), args: .success(argsBytes(["x", "--flag"])))).loadDetails(for: identity)
        #expect(d.identity == identity)
        #expect(d.commandLine.value?.arguments == ["x", "--flag"])
        #expect(d.threadCount == .value(4))
        #expect(d.virtualBytes == .value(2048))
    }

    @Test func environmentNeverReachesTheResult() {
        let d = collector(DetailsAPI(bsd: .success(bsd()), args: .success(argsBytes(["x"])))).loadDetails(for: identity)
        #expect(!(d.commandLine.value?.arguments.joined().contains("SECRET") ?? true))
    }

    @Test func reusedPIDIsReportedAsExitedNotAsTheNewProcess() {
        let d = collector(DetailsAPI(bsd: .success(bsd(start: 999)), args: .success(argsBytes(["evil"])))).loadDetails(for: identity)
        #expect(d == .unavailable(identity, .processExited))
    }

    @Test func pidOnlyIdentityIsUnavailable() {
        let d = collector(DetailsAPI(bsd: .success(bsd()), args: .success([]))).loadDetails(for: ProcessIdentity(pid: 9, start: nil))
        #expect(d.commandLine == .unavailable(.collectionFailed))
    }

    @Test func inaccessibleCommandLineKeepsTheOtherFields() {
        let api = DetailsAPI(bsd: .success(bsd()), args: .failure(DetailsAPI.errno(EPERM)))
        let d = collector(api).loadDetails(for: identity)
        #expect(d.commandLine == .unavailable(.permissionDenied))
        #expect(d.threadCount == .value(4))
    }

    @Test func malformedBufferIsUnavailableNotEmpty() {
        let d = collector(DetailsAPI(bsd: .success(bsd()), args: .success([1, 2]))).loadDetails(for: identity)
        #expect(d.commandLine == .unavailable(.malformed))
    }

    @Test func taskInfoFailureMarksOnlyThoseFields() {
        var api = DetailsAPI(bsd: .success(bsd()), args: .success(argsBytes(["x"])))
        api.task = .failure(DetailsAPI.errno(EPERM))
        let d = collector(api).loadDetails(for: identity)
        #expect(d.commandLine.value != nil)
        #expect(d.threadCount == .unavailable(.permissionDenied))
        #expect(d.virtualBytes == .unavailable(.permissionDenied))
    }

    @Test func exitedProcessIsReported() {
        let d = collector(DetailsAPI(bsd: .failure(DetailsAPI.errno(ESRCH)), args: .success([]))).loadDetails(for: identity)
        #expect(d == .unavailable(identity, .processExited))
    }

    @Test func liveChildCommandLineIsReadFromTheKernel() throws {
        let child = try SpawnedChild("/bin/sleep", ["31337"])
        defer { child.cleanup() } // only a process this test spawned
        let bsd = try NativeProbe.bsdInfo(pid: child.pid)
        let id = ProcessIdentity(
            pid: child.pid, start: ProcessStartTime(seconds: bsd.startSeconds, microseconds: bsd.startMicroseconds))
        let d = DarwinCollector().loadDetails(for: id)
        #expect(d.commandLine.value?.arguments == ["/bin/sleep", "31337"])
        #expect((d.threadCount.value ?? 0) >= 1)
        #expect((d.virtualBytes.value ?? 0) > 0)
    }
}

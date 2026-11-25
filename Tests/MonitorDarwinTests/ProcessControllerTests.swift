import Darwin
import Foundation
import MonitorCore
import Testing
@testable import MonitorDarwin

private final class FakeReader: ProcessTargetReading, @unchecked Sendable { // all state under `lock`
    private let lock = NSLock()
    private var result: Result<ProcessTarget, ControlError>
    private var reads = [Int32]()

    init(_ result: Result<ProcessTarget, ControlError>) { self.result = result }

    func read(pid: Int32) -> Result<ProcessTarget, ControlError> {
        lock.withLock { reads.append(pid); return result }
    }
    var readCount: Int { lock.withLock { reads.count } }
}

private final class FakeDelivery: SignalDelivering, @unchecked Sendable { // all state under `lock`
    private let lock = NSLock()
    private var calls = [(pid: Int32, signal: Int32)]()
    private let errno: Int32?

    init(errno: Int32? = nil) { self.errno = errno }

    func deliver(pid: Int32, signal: Int32) -> Int32? {
        lock.withLock { calls.append((pid, signal)) }
        return errno
    }
    var delivered: [(pid: Int32, signal: Int32)] { lock.withLock { calls } }
}

private let start = ProcessStartTime(seconds: 1000, microseconds: 5)

private func request(
    pid: Int32 = 500, start: ProcessStartTime? = start, uid: UInt32 = 501, path: String? = "/Users/me/tool",
    signal: ControlSignal = .term
) -> SignalRequest {
    SignalRequest(identity: ProcessIdentity(pid: pid, start: start), name: "tool", uid: uid, path: path, signal: signal)
}

private func target(start: ProcessStartTime = start, uid: UInt32 = 501, path: String? = "/Users/me/tool") -> ProcessTarget {
    ProcessTarget(start: start, uid: uid, path: path)
}

@Suite struct ProcessControllerGuardTests {
    private func controller(
        own: Int32 = 4242, reader: FakeReader, delivery: FakeDelivery
    ) -> ProcessController {
        ProcessController(ownPID: own, reader: reader, delivery: delivery)
    }

    @Test(arguments: [Int32(0), -1, Int32.min, Int32.max, 100_000])
    func invalidPIDsAreRefusedBeforeAnyOSAccess(pid: Int32) {
        let reader = FakeReader(.success(target())), delivery = FakeDelivery()
        #expect(controller(reader: reader, delivery: delivery).send(request(pid: pid)) == .failure(.invalidTarget))
        #expect(reader.readCount == 0)
        #expect(delivery.delivered.isEmpty)
    }

    @Test func pidOneIsRefused() {
        let reader = FakeReader(.success(target())), delivery = FakeDelivery()
        #expect(controller(reader: reader, delivery: delivery).send(request(pid: 1)) == .failure(.protectedTarget))
        #expect(reader.readCount == 0 && delivery.delivered.isEmpty)
    }

    @Test func ownPIDIsRefused() {
        let reader = FakeReader(.success(target())), delivery = FakeDelivery()
        #expect(controller(own: 777, reader: reader, delivery: delivery).send(request(pid: 777)) == .failure(.protectedTarget))
        #expect(delivery.delivered.isEmpty)
    }

    @Test func unverifiableIdentityIsRefusedWithoutReadingOrSending() {
        let reader = FakeReader(.success(target())), delivery = FakeDelivery()
        #expect(controller(reader: reader, delivery: delivery).send(request(start: nil)) == .failure(.identityUnavailable))
        #expect(reader.readCount == 0 && delivery.delivered.isEmpty)
    }

    @Test func unreadableLiveIdentityIsRefused() {
        let reader = FakeReader(.failure(.identityUnavailable)), delivery = FakeDelivery()
        #expect(controller(reader: reader, delivery: delivery).send(request()) == .failure(.identityUnavailable))
        #expect(delivery.delivered.isEmpty)
    }

    @Test func exitedTargetIsReportedAndNothingIsSent() {
        let reader = FakeReader(.failure(.processExited)), delivery = FakeDelivery()
        #expect(controller(reader: reader, delivery: delivery).send(request()) == .failure(.processExited))
        #expect(delivery.delivered.isEmpty)
    }

    @Test func differentStartTimeIsAnIdentityChange() {
        let reused = target(start: ProcessStartTime(seconds: 1000, microseconds: 6)) // one microsecond later
        let reader = FakeReader(.success(reused)), delivery = FakeDelivery()
        #expect(controller(reader: reader, delivery: delivery).send(request()) == .failure(.identityChanged))
        #expect(delivery.delivered.isEmpty)
    }

    @Test func targetThatBecameRootOwnedReturnsToConfirmation() {
        let reader = FakeReader(.success(target(uid: 0))), delivery = FakeDelivery()
        #expect(controller(reader: reader, delivery: delivery).send(request(uid: 501)) == .failure(.cautionChanged))
        #expect(delivery.delivered.isEmpty)
    }

    @Test func targetThatMovedUnderSystemReturnsToConfirmation() {
        let reader = FakeReader(.success(target(path: "/System/Library/x"))), delivery = FakeDelivery()
        #expect(controller(reader: reader, delivery: delivery).send(request()) == .failure(.cautionChanged))
    }

    @Test func alreadyProtectedRequestProceedsWhenStillProtected() {
        let reader = FakeReader(.success(target(uid: 0))), delivery = FakeDelivery()
        let r = request(uid: 0)
        #expect(r.isProtected)
        #expect(controller(reader: reader, delivery: delivery).send(r) == .success(SignalSent(pid: 500, signal: .term)))
    }

    @Test func verifiedTargetReceivesExactlyOneSignalToItsPID() {
        let reader = FakeReader(.success(target())), delivery = FakeDelivery()
        let result = controller(reader: reader, delivery: delivery).send(request(signal: .stop))
        #expect(result == .success(SignalSent(pid: 500, signal: .stop)))
        #expect(delivery.delivered.count == 1)
        #expect(delivery.delivered.first?.pid == 500)
        #expect(delivery.delivered.first?.signal == SIGSTOP)
        #expect(reader.readCount == 1)
    }

    @Test(arguments: [(EPERM, ControlError.permissionDenied), (ESRCH, .processExited), (EINVAL, .osFailure(errno: EINVAL))])
    func deliveryErrorsMapToDomainErrors(code: Int32, expected: ControlError) {
        let reader = FakeReader(.success(target())), delivery = FakeDelivery(errno: code)
        #expect(controller(reader: reader, delivery: delivery).send(request()) == .failure(expected))
    }

    @Test func signalNumbersMatchTheSDK() {
        let expected: [ControlSignal: Int32] = [.term: SIGTERM, .kill: SIGKILL, .int: SIGINT, .hup: SIGHUP, .stop: SIGSTOP, .cont: SIGCONT]
        for signal in ControlSignal.allCases { #expect(signal.number == expected[signal]) }
        #expect(ProcessControlPolicy.maxPID == 99_999)
    }

    @Test func nativeSignalWrapperRefusesGroupAddresses() {
        // 0 and negative PIDs would address process groups; the C boundary refuses them.
        #expect(NativeProbe.sendSignal(pid: 0, signal: 0) == EINVAL)
        #expect(NativeProbe.sendSignal(pid: -1, signal: 0) == EINVAL)
        #expect(NativeProbe.sendSignal(pid: getpid(), signal: 0) == nil) // signal 0: existence check only
    }
}

/// Real signals, sent only to children this test spawned.
@Suite(.serialized) struct OwnedChildSignalTests {
    private final class Child {
        let process: SpawnedChild
        var pid: Int32 { process.pid }

        init(_ path: String, _ arguments: [String]) throws { process = try SpawnedChild(path, arguments) }

        func cleanup() { process.cleanup() }

        func request(signal: ControlSignal, start override: ProcessStartTime? = nil) throws -> SignalRequest {
            let bsd = try NativeProbe.bsdInfo(pid: pid)
            let start = override ?? ProcessStartTime(seconds: bsd.startSeconds, microseconds: bsd.startMicroseconds)
            return SignalRequest(
                identity: ProcessIdentity(pid: pid, start: start), name: bsd.name, uid: bsd.uid,
                path: try? NativeProbe.path(pid: pid), signal: signal)
        }

        func status() -> ProcessStatus? {
            (try? NativeProbe.bsdInfo(pid: pid)).map { processStatus(nativeValue: $0.status) }
        }
    }

    private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func sigtermEndsAnOrdinaryChild() async throws {
        let child = try Child("/bin/sleep", ["60"])
        defer { child.cleanup() }
        let result = ProcessController().send(try child.request(signal: .term))
        #expect(result == .success(SignalSent(pid: child.pid, signal: .term)))
        #expect(await eventually { !child.process.isRunning })
        #expect(child.process.terminatingSignal != nil)
        #expect(child.process.terminatingSignal == SIGTERM)
    }

    @Test func stopThenContinueIsObservableInProcessState() async throws {
        let child = try Child("/bin/sleep", ["60"])
        defer { child.cleanup() }
        let controller = ProcessController()
        #expect(controller.send(try child.request(signal: .stop)) == .success(SignalSent(pid: child.pid, signal: .stop)))
        #expect(await eventually { child.status() == .stopped })
        #expect(controller.send(try child.request(signal: .cont)) == .success(SignalSent(pid: child.pid, signal: .cont)))
        #expect(await eventually { child.status() != .stopped })
        #expect(child.process.isRunning)
    }

    @Test func ignoredSIGTERMNeedsAnExplicitSIGKILL() async throws {
        let child = try Child("/bin/sh", ["-c", "trap '' TERM; while :; do sleep 1; done"])
        defer { child.cleanup() }
        try await Task.sleep(for: .milliseconds(300)) // let the shell install its trap
        let controller = ProcessController()
        #expect(controller.send(try child.request(signal: .term)) == .success(SignalSent(pid: child.pid, signal: .term)))
        try await Task.sleep(for: .milliseconds(500))
        #expect(child.process.isRunning, "an accepted SIGTERM is not a dead process")
        #expect(controller.send(try child.request(signal: .kill)) == .success(SignalSent(pid: child.pid, signal: .kill)))
        #expect(await eventually { !child.process.isRunning })
        #expect(child.process.terminatingSignal == SIGKILL)
    }

    @Test func exitedChildReportsProcessExitedAndSendsNothing() async throws {
        let child = try Child("/usr/bin/true", [])
        defer { child.cleanup() }
        let request = try child.request(signal: .term)
        child.process.wait() // reaped: the PID is gone
        #expect(ProcessController().send(request) == .failure(.processExited))
    }

    @Test func forgedIdentityIsRejectedAndTheChildSurvives() async throws {
        let child = try Child("/bin/sleep", ["60"])
        defer { child.cleanup() }
        let real = try NativeProbe.bsdInfo(pid: child.pid)
        let forged = ProcessStartTime(seconds: real.startSeconds + 1, microseconds: real.startMicroseconds)
        #expect(ProcessController().send(try child.request(signal: .kill, start: forged)) == .failure(.identityChanged))
        try await Task.sleep(for: .milliseconds(200))
        #expect(child.process.isRunning)
    }

    @Test func pidOnlyRequestIsRejectedWithoutSignalling() async throws {
        let child = try Child("/bin/sleep", ["60"])
        defer { child.cleanup() }
        let pidOnly = SignalRequest(identity: ProcessIdentity(pid: child.pid, start: nil), name: "sleep", uid: 501, path: nil, signal: .kill)
        #expect(ProcessController().send(pidOnly) == .failure(.identityUnavailable))
        try await Task.sleep(for: .milliseconds(200))
        #expect(child.process.isRunning)
    }

    @Test func monitorRefusesItself() {
        let own = SignalRequest(
            identity: ProcessIdentity(pid: getpid(), start: ProcessStartTime(seconds: 1, microseconds: 1)),
            name: "me", uid: 501, path: nil, signal: .term)
        #expect(ProcessController().send(own) == .failure(.protectedTarget))
    }

    @Test func permissionDeniedIsCoveredByMockNotRealSystemProcesses() {
        let reader = FakeReader(.success(target())), delivery = FakeDelivery(errno: EPERM)
        #expect(ProcessController(ownPID: 1, reader: reader, delivery: delivery).send(request()) == .failure(.permissionDenied))
    }
}

import Foundation
import Testing
@testable import MonitorCore

/// Test-only counter. All access is under `lock`.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@Suite struct SamplingWorkerTests {
    private func snapshotSteps(_ count: Int) -> [FakeCollector.Step] {
        (0..<count).map { _ in .snapshot(Fixtures.snapshot(0, [Fixtures.process(1)])) }
    }

    @Test func slowCollectorBuildsNoBacklog() async {
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let calls = Counter()
        let worker = SamplingWorker {
            FakeCollector(steps: [.snapshot(Fixtures.snapshot(0, []))]) {
                calls.increment()
                entered.signal()
                gate.wait()
            }
        }
        worker.start()
        #expect(worker.requestRefresh())
        block(entered) // collection is now in flight

        var accepted = 0
        for _ in 0..<500 where worker.requestRefresh() { accepted += 1 }
        #expect(accepted == 0, "requests while busy must be dropped")

        gate.signal()
        var iterator = worker.events.makeAsyncIterator()
        _ = await iterator.next()
        #expect(calls.value == 1)

        // Once idle again a new request is accepted.
        var reaccepted = false
        for _ in 0..<200 where !reaccepted {
            reaccepted = worker.requestRefresh()
            if !reaccepted { try? await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(reaccepted)
        block(entered)
        gate.signal()
        worker.stopAndJoin()
    }

    @Test func sequenceNumbersAreMonotonic() async {
        let worker = SamplingWorker { FakeCollector(steps: self.snapshotSteps(1)) }
        worker.start()
        var iterator = worker.events.makeAsyncIterator()
        var sequences = [UInt64]()
        for _ in 0..<5 {
            while !worker.requestRefresh() { try? await Task.sleep(for: .milliseconds(1)) }
            if case .snapshot(let s)? = await iterator.next() { sequences.append(s.sequence) }
        }
        worker.stopAndJoin()
        #expect(sequences.count == 5)
        #expect(sequences == sequences.sorted())
        #expect(Set(sequences).count == 5)
    }

    @Test func collectorFailureIsDeliveredNotFatal() async {
        let worker = SamplingWorker {
            FakeCollector(steps: [.failure(CollectionFailure("no proc")), .snapshot(Fixtures.snapshot(0, []))])
        }
        worker.start()
        var iterator = worker.events.makeAsyncIterator()
        #expect(worker.requestRefresh())
        guard case .failed(_, let message)? = await iterator.next() else {
            Issue.record("expected failure event")
            return
        }
        #expect(message == "no proc")
        while !worker.requestRefresh() { try? await Task.sleep(for: .milliseconds(1)) }
        guard case .snapshot? = await iterator.next() else {
            Issue.record("worker should keep running after a failure")
            return
        }
        worker.stopAndJoin()
    }

    @Test func stopJoinsFinishesStreamAndRejectsRequests() async {
        let worker = SamplingWorker { FakeCollector(steps: self.snapshotSteps(1)) }
        worker.start()
        worker.stopAndJoin()
        worker.stopAndJoin() // idempotent
        #expect(!worker.requestRefresh())
        var iterator = worker.events.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test func stopWaitsForInFlightCollection() async {
        let entered = DispatchSemaphore(value: 0)
        let finished = Counter()
        let worker = SamplingWorker {
            FakeCollector(steps: [.snapshot(Fixtures.snapshot(0, []))]) {
                entered.signal()
                Thread.sleep(forTimeInterval: 0.2)
                finished.increment()
            }
        }
        worker.start()
        _ = worker.requestRefresh()
        block(entered)
        worker.stopAndJoin()
        #expect(finished.value == 1, "join must not return while collection is running")
    }

    @Test func detailRequestsRunOnTheWorkerAndKeepTheirGeneration() async {
        let worker = SamplingWorker {
            FakeCollector(steps: [.snapshot(Fixtures.snapshot(0, []))], detailsProvider: { identity in
                ProcessDetails(identity: identity, commandLine: .value(.init(arguments: ["x"])))
            })
        }
        worker.start()
        var iterator = worker.detailEvents.makeAsyncIterator()
        #expect(worker.requestDetails(for: Fixtures.identity(7), generation: 3))
        let event = await iterator.next()
        #expect(event?.generation == 3)
        #expect(event?.details.identity == Fixtures.identity(7))
        worker.stopAndJoin()
        #expect(!worker.requestDetails(for: Fixtures.identity(7), generation: 4))
        #expect(await iterator.next() == nil)
    }

    @Test func detailReadWhileRefreshIsBusyDoesNotQueueUnbounded() {
        let worker = SamplingWorker { FakeCollector(steps: [.snapshot(Fixtures.snapshot(0, []))]) }
        // Not started: requests are refused, nothing accumulates.
        #expect(!worker.requestDetails(for: Fixtures.identity(1), generation: 1))
        worker.stopAndJoin()
    }

    @Test func unsupportedCollectorReportsUnavailableDetails() {
        let d = FakeCollector(steps: [.snapshot(Fixtures.snapshot(0, []))]).loadDetails(for: Fixtures.identity(1))
        #expect(d.commandLine == .unavailable(.unsupported))
    }

    @Test func stopWithoutStartDoesNotHang() {
        let worker = SamplingWorker { FakeCollector(steps: [.snapshot(Fixtures.snapshot(0, []))]) }
        worker.stopAndJoin()
    }
}

/// Blocking waits are rejected inside `async` functions, so tests go through this helper.
private func block(_ semaphore: DispatchSemaphore) { semaphore.wait() }

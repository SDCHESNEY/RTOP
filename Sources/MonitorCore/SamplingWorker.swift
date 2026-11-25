import Foundation

public enum SamplerEvent: Sendable, Equatable {
    case snapshot(Snapshot)
    case failed(sequence: UInt64, message: String)
}

/// A finished detail read, tagged so the reducer can discard stale ones.
public struct DetailsEvent: Sendable, Equatable {
    public var generation: UInt64
    public var details: ProcessDetails
}

/// Owns a collector on a dedicated thread.
///
/// - At most one refresh is in flight; a request made while one is running or
///   already queued is dropped (the return value says so), so a slow collector
///   can never build a backlog.
/// - Results flow through an `AsyncStream` that keeps only the newest event.
/// - Detail reads run on the same thread. Only the newest request is kept, and
///   its reply travels on its own stream so a snapshot can never displace it.
/// - `stopAndJoin()` waits for any in-flight collection to finish.
///
/// `@unchecked Sendable` invariant: every mutable stored property is read and
/// written only while holding `condition`, except `thread`, which is written
/// once in `start()` before any other thread can observe it.
public final class SamplingWorker: @unchecked Sendable {
    public let events: AsyncStream<SamplerEvent>
    public let detailEvents: AsyncStream<DetailsEvent>

    private let continuation: AsyncStream<SamplerEvent>.Continuation
    private let detailContinuation: AsyncStream<DetailsEvent>.Continuation
    private var pendingDetails: (identity: ProcessIdentity, generation: UInt64)?
    private let makeCollector: @Sendable () -> any SystemCollector
    private let condition = NSCondition()
    private var requested = false
    private var inFlight = false
    private var joined = false
    private var started = false
    private var stopping = false
    private var nextSequence: UInt64 = 1
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)

    /// `makeCollector` runs on the worker thread so the collector (which is
    /// not `Sendable`) never crosses a thread boundary.
    public init(makeCollector: @escaping @Sendable () -> any SystemCollector) {
        self.makeCollector = makeCollector
        let (stream, continuation) = AsyncStream<SamplerEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.events = stream
        self.continuation = continuation
        let (detailStream, detailContinuation) =
            AsyncStream<DetailsEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.detailEvents = detailStream
        self.detailContinuation = detailContinuation
    }

    /// Replaces any detail request not yet started. Returns false if stopping or not started.
    @discardableResult
    public func requestDetails(for identity: ProcessIdentity, generation: UInt64) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard started, !stopping else { return false }
        pendingDetails = (identity, generation)
        condition.signal()
        return true
    }

    public func start() {
        condition.lock()
        defer { condition.unlock() }
        guard !started else { return }
        started = true
        let t = Thread { [self] in run() }
        t.name = "rtop.sampler"
        t.qualityOfService = .utility
        thread = t
        t.start()
    }

    /// Returns false when the request was dropped (busy, queued, or stopping).
    @discardableResult
    public func requestRefresh() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard started, !stopping, !requested, !inFlight else { return false }
        requested = true
        condition.signal()
        return true
    }

    /// Stops the worker and blocks until its thread has exited.
    public func stopAndJoin() {
        condition.lock()
        let mustJoin = started && !joined
        joined = true
        stopping = true
        condition.signal()
        condition.unlock()
        if mustJoin { finished.wait() }
        continuation.finish()
        detailContinuation.finish()
    }

    private func run() {
        let collector = makeCollector()
        while true {
            condition.lock()
            while !requested && pendingDetails == nil && !stopping { condition.wait() }
            if stopping {
                condition.unlock()
                break
            }
            if let job = pendingDetails { // cheap and user-driven: ahead of the next refresh
                pendingDetails = nil
                condition.unlock()
                detailContinuation.yield(DetailsEvent(
                    generation: job.generation, details: collector.loadDetails(for: job.identity)))
                continue
            }
            requested = false
            inFlight = true
            let sequence = nextSequence
            nextSequence += 1
            condition.unlock()

            do {
                var snapshot = try collector.collect()
                snapshot.sequence = sequence
                continuation.yield(.snapshot(snapshot))
            } catch {
                continuation.yield(.failed(sequence: sequence, message: "\(error)"))
            }

            condition.lock()
            inFlight = false
            condition.unlock()
        }
        finished.signal()
    }
}

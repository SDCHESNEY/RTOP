import Darwin
import Dispatch
import Foundation
import MonitorCore

public enum InputEvent: Sendable, Equatable {
    case key(KeyEvent)
    case resize
    /// SIGINT, SIGTERM or SIGHUP arrived through the signal bridge.
    case terminate
    /// stdin closed or the terminal went away.
    case endOfInput
}

/// Reads stdin and the signal-bridge pipe on one dedicated thread and reports
/// decoded events. The thread owns the decoder, so decoding needs no locking,
/// and it resolves a lone ESC after `escapeTimeoutMilliseconds`.
///
/// `@unchecked Sendable` invariant: `stopRequested` and `started` are only
/// accessed under `lock`; everything else is immutable or confined to the
/// pump thread.
public final class TerminalInputPump: @unchecked Sendable {
    private let inputFD: Int32
    private let signalFD: Int32
    private let escapeTimeoutNanoseconds: UInt64
    private let handler: @Sendable (InputEvent) -> Void
    private let lock = NSLock()
    private var stopRequested = false
    private var started = false
    private let finished = DispatchSemaphore(value: 0)

    /// Upper bound on how long the thread sleeps, i.e. stop latency.
    private static let pollSliceMilliseconds: Int32 = 50

    public init(
        inputFD: Int32 = STDIN_FILENO, signalFD: Int32, escapeTimeoutMilliseconds: Int = 40,
        handler: @escaping @Sendable (InputEvent) -> Void
    ) {
        self.inputFD = inputFD
        self.signalFD = signalFD
        self.escapeTimeoutNanoseconds = UInt64(max(1, escapeTimeoutMilliseconds)) * 1_000_000
        self.handler = handler
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        let thread = Thread { [self] in run() }
        thread.name = "rtop.input"
        thread.start()
    }

    /// Stops the thread and waits for it to exit. Safe to call more than once.
    public func stopAndJoin() {
        lock.lock()
        let mustJoin = started && !stopRequested
        stopRequested = true
        lock.unlock()
        if mustJoin { finished.wait() }
    }

    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    private func run() {
        defer { finished.signal() }
        var decoder = InputDecoder()
        var escapeDeadline: UInt64?
        var fds = [
            pollfd(fd: inputFD, events: Int16(POLLIN), revents: 0),
            pollfd(fd: signalFD, events: Int16(POLLIN), revents: 0),
        ]

        while !shouldStop {
            var timeout = Self.pollSliceMilliseconds
            if let deadline = escapeDeadline {
                let now = DispatchTime.now().uptimeNanoseconds
                let remaining = deadline > now ? Int32((deadline - now) / 1_000_000) + 1 : 0
                timeout = min(timeout, remaining)
            }

            let ready = poll(&fds, nfds_t(fds.count), timeout)
            if ready < 0 {
                if errno == EINTR { continue }
                handler(.endOfInput)
                return
            }
            if ready == 0 {
                if let deadline = escapeDeadline, DispatchTime.now().uptimeNanoseconds >= deadline {
                    for key in decoder.flushPendingEscape() { handler(.key(key)) }
                    escapeDeadline = nil
                }
                continue
            }

            if fds[1].revents & Int16(POLLIN) != 0 { drainSignals() }

            if fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                var buffer = [UInt8](repeating: 0, count: 256)
                let count = read(inputFD, &buffer, buffer.count)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                if count <= 0 {
                    handler(.endOfInput) // EOF, or EIO after terminal disconnect
                    return
                }
                for key in decoder.feed(Array(buffer.prefix(count))) { handler(.key(key)) }
                escapeDeadline = decoder.hasPendingEscape
                    ? DispatchTime.now().uptimeNanoseconds + escapeTimeoutNanoseconds
                    : nil
            }
        }
    }

    /// Any number of bytes may be queued (the C side drops when full); each
    /// distinct kind of event is reported once per drain, which is enough
    /// because the consumer re-reads state rather than counting signals.
    private func drainSignals() {
        var buffer = [UInt8](repeating: 0, count: 64)
        var sawResize = false
        var sawTerminate = false
        while true {
            let count = read(signalFD, &buffer, buffer.count)
            if count <= 0 { break }
            for byte in buffer.prefix(count) {
                switch Int32(byte) {
                case SIGWINCH: sawResize = true
                case SIGINT, SIGTERM, SIGHUP: sawTerminate = true
                default: break
                }
            }
        }
        if sawResize { handler(.resize) }
        if sawTerminate { handler(.terminate) }
    }
}

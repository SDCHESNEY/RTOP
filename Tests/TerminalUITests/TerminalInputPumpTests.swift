import Darwin
import Foundation
import MonitorCore
import Testing
import DarwinSupport
@testable import TerminalUI

/// Collects pump events. All access is under `lock`.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events = [InputEvent]()
    func append(_ e: InputEvent) { lock.lock(); events.append(e); lock.unlock() }
    var snapshot: [InputEvent] { lock.lock(); defer { lock.unlock() }; return events }

    func waitFor(count: Int, timeout: TimeInterval = 2) async -> [InputEvent] {
        let deadline = Date().addingTimeInterval(timeout)
        while snapshot.count < count, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return snapshot
    }
}

@Suite(.serialized) struct TerminalInputPumpTests {
    private struct Pipes {
        var input: [Int32] = [0, 0]
        var signal: [Int32] = [0, 0]
        init() {
            precondition(pipe(&input) == 0 && pipe(&signal) == 0)
            for fd in [input[0], signal[0]] { _ = fcntl(fd, F_SETFL, O_NONBLOCK) }
        }
        func close() { for fd in input + signal { Darwin.close(fd) } }
        func send(_ s: String) { let b = Array(s.utf8); _ = Darwin.write(input[1], b, b.count) }
    }

    @Test func decodesKeysAndResolvesLoneEscapeAfterTimeout() async {
        let pipes = Pipes(); defer { pipes.close() }
        let log = EventLog()
        let pump = TerminalInputPump(inputFD: pipes.input[0], signalFD: pipes.signal[0],
                                     escapeTimeoutMilliseconds: 30) { log.append($0) }
        pump.start()
        pipes.send("j\u{1B}[B")
        pipes.send("\u{1B}")
        let events = await log.waitFor(count: 3)
        pump.stopAndJoin()
        #expect(events == [.key(.character("j")), .key(.down), .key(.escape)])
    }

    @Test func escapeSequenceSplitAcrossReadsIsNotAnEscape() async {
        let pipes = Pipes(); defer { pipes.close() }
        let log = EventLog()
        let pump = TerminalInputPump(inputFD: pipes.input[0], signalFD: pipes.signal[0],
                                     escapeTimeoutMilliseconds: 200) { log.append($0) }
        pump.start()
        pipes.send("\u{1B}")
        try? await Task.sleep(for: .milliseconds(50)) // shorter than the timeout
        pipes.send("[A")
        let events = await log.waitFor(count: 1)
        pump.stopAndJoin()
        #expect(events == [.key(.up)])
    }

    @Test func signalBridgeBytesBecomeResizeAndTerminate() async {
        let pipes = Pipes(); defer { pipes.close() }
        let log = EventLog()
        let pump = TerminalInputPump(inputFD: pipes.input[0], signalFD: pipes.signal[0]) { log.append($0) }
        pump.start()
        var winch = UInt8(SIGWINCH), term = UInt8(SIGTERM)
        _ = write(pipes.signal[1], &winch, 1)
        _ = write(pipes.signal[1], &term, 1)
        let events = await log.waitFor(count: 2)
        pump.stopAndJoin()
        #expect(events.contains(.resize))
        #expect(events.contains(.terminate))
    }

    @Test func manyQueuedSignalsCoalesceIntoOneEventPerKind() async {
        let pipes = Pipes(); defer { pipes.close() }
        let log = EventLog()
        var bytes = [UInt8](repeating: UInt8(SIGWINCH), count: 40)
        _ = write(pipes.signal[1], &bytes, bytes.count) // queued before the pump starts
        let pump = TerminalInputPump(inputFD: pipes.input[0], signalFD: pipes.signal[0]) { log.append($0) }
        pump.start()
        _ = await log.waitFor(count: 1)
        try? await Task.sleep(for: .milliseconds(100))
        pump.stopAndJoin()
        #expect(log.snapshot == [.resize])
    }

    @Test func endOfInputIsReportedOnceAndPumpExits() async {
        let pipes = Pipes(); defer { pipes.close() }
        let log = EventLog()
        let pump = TerminalInputPump(inputFD: pipes.input[0], signalFD: pipes.signal[0]) { log.append($0) }
        pump.start()
        Darwin.close(pipes.input[1]) // EOF
        let events = await log.waitFor(count: 1)
        pump.stopAndJoin()
        #expect(events == [.endOfInput])
    }

    @Test func stopJoinsPromptlyAndIsIdempotent() {
        let pipes = Pipes(); defer { pipes.close() }
        let pump = TerminalInputPump(inputFD: pipes.input[0], signalFD: pipes.signal[0]) { _ in }
        pump.start()
        let started = Date()
        pump.stopAndJoin()
        pump.stopAndJoin()
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func stopWithoutStartDoesNotHang() {
        let pipes = Pipes(); defer { pipes.close() }
        TerminalInputPump(inputFD: pipes.input[0], signalFD: pipes.signal[0]) { _ in }.stopAndJoin()
    }
}

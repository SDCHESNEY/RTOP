import Darwin
import Foundation
import Testing
import DarwinSupport
@testable import TerminalUI

/// Drives `TerminalSession` against a pseudo-terminal so no real terminal is touched.
@Suite(.serialized) struct TerminalSessionTests {
    /// A pty pair with a background reader on the master. A reader is required:
    /// `tcsetattr(TCSAFLUSH)` waits for queued output to drain, which blocks
    /// forever if nothing consumes the master side (a real terminal always does).
    private final class PTY: @unchecked Sendable { // all mutable state guarded by `lock`
        private(set) var master: Int32 = -1
        private(set) var slave: Int32 = -1
        private let lock = NSLock()
        private var captured = [UInt8]()
        private var reader: Thread?

        init() {
            precondition(openpty(&master, &slave, nil, nil, nil) == 0)
            let fd = master
            let t = Thread { [self] in
                var buf = [UInt8](repeating: 0, count: 256)
                while true {
                    let n = read(fd, &buf, buf.count)
                    if n <= 0 { break }
                    lock.lock(); captured += buf.prefix(n); lock.unlock()
                }
            }
            reader = t
            t.start()
        }

        func close() {
            Darwin.close(slave) // master read then fails with EIO and the reader exits
            Darwin.close(master)
        }

        /// Returns everything captured so far, then clears it.
        func drain() -> String {
            usleep(50_000) // let the reader catch up with writes already issued
            lock.lock(); defer { lock.unlock() }
            let s = String(decoding: captured, as: UTF8.self)
            captured.removeAll()
            return s
        }
    }

    @Test func entersRawModeAndRestoresExactSettings() throws {
        let pty = PTY(); defer { pty.close() }
        var original = termios()
        #expect(tcgetattr(pty.slave, &original) == 0)

        let session = TerminalSession(inputFD: pty.slave, outputFD: pty.slave)
        try session.enter()
        #expect(session.isActive)

        var raw = termios()
        #expect(tcgetattr(pty.slave, &raw) == 0)
        #expect(raw.c_lflag & tcflag_t(ICANON | ECHO | ISIG) == 0)

        session.restore()
        #expect(!session.isActive)
        var after = termios()
        #expect(tcgetattr(pty.slave, &after) == 0)
        #expect(after.c_iflag == original.c_iflag)
        #expect(after.c_oflag == original.c_oflag)
        #expect(after.c_cflag == original.c_cflag)
        #expect(after.c_lflag == original.c_lflag)

        let output = pty.drain()
        #expect(output.contains("\u{1B}[?1049h"))
        #expect(output.contains("\u{1B}[?25l"))
        #expect(output.contains("\u{1B}[?25h"))
        #expect(output.contains("\u{1B}[?1049l"))
    }

    @Test func restoreIsIdempotent() throws {
        let pty = PTY(); defer { pty.close() }
        let session = TerminalSession(inputFD: pty.slave, outputFD: pty.slave)
        try session.enter()
        session.restore()
        _ = pty.drain()
        session.restore()
        #expect(pty.drain().isEmpty)
    }

    @Test func deinitRestoresTerminal() throws {
        let pty = PTY(); defer { pty.close() }
        var original = termios()
        _ = tcgetattr(pty.slave, &original)
        do {
            let session = TerminalSession(inputFD: pty.slave, outputFD: pty.slave)
            try session.enter()
        }
        var after = termios()
        _ = tcgetattr(pty.slave, &after)
        #expect(after.c_lflag == original.c_lflag)
    }

    @Test func refusesNonTerminal() {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let session = TerminalSession(inputFD: fds[0], outputFD: fds[1])
        #expect(throws: TerminalError.notATerminal) { try session.enter() }
        #expect(!session.isActive)
    }

    @Test func signalBridgeDeliversSignalNumbers() throws {
        var fd: Int32 = -1
        #expect(ds_signal_bridge_install(&fd).kind == DS_OK)
        defer { ds_signal_bridge_remove() }

        raise(SIGWINCH)
        var byte: UInt8 = 0
        var got = 0
        for _ in 0..<50 { // signal delivery to self is synchronous, but allow slack
            got = read(fd, &byte, 1)
            if got == 1 { break }
            usleep(2000)
        }
        #expect(got == 1)
        #expect(Int32(byte) == SIGWINCH)
    }

    @Test func signalBridgeSurvivesFullPipe() {
        var fd: Int32 = -1
        #expect(ds_signal_bridge_install(&fd).kind == DS_OK)
        defer { ds_signal_bridge_remove() }
        // Far more signals than a pipe buffer holds; the handler must drop, not block.
        for _ in 0..<100_000 { raise(SIGWINCH) }
        var byte: UInt8 = 0
        #expect(read(fd, &byte, 1) == 1)
    }
}

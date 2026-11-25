import Darwin
import Foundation

/// A child process started with `posix_spawn` and reaped with `waitpid`.
///
/// Foundation's `Process` can deadlock when several tests spawn and wait on
/// children concurrently, so tests that signal children use this instead. It
/// only ever signals or waits on the one PID it spawned.
final class SpawnedChild: @unchecked Sendable { // `status` is guarded by `lock`
    let pid: pid_t
    private let lock = NSLock()
    private var status: Int32?

    init(_ path: String, _ arguments: [String]) throws {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        // The test process may have ignored or blocked signals (other suites install
        // handlers); a child inherits ignored ones, so reset to defaults and unblock.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var allSignals = sigset_t(), noSignals = sigset_t()
        sigfillset(&allSignals)
        sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var child: pid_t = 0
        let rc = posix_spawn(&child, path, &actions, &attributes, argv, environ)
        guard rc == 0 else { throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EINVAL) }
        pid = child
    }

    private func reap(options: Int32) {
        lock.withLock {
            guard status == nil else { return }
            var s: Int32 = 0
            if waitpid(pid, &s, options) == pid { status = s }
        }
    }

    var isRunning: Bool {
        reap(options: WNOHANG)
        return lock.withLock { status == nil }
    }

    /// Blocks until the child has exited and been reaped.
    func wait() { reap(options: 0) }

    /// The signal that ended the child, if it died from one.
    var terminatingSignal: Int32? {
        lock.withLock {
            guard let s = status, (s & 0x7F) != 0, (s & 0x7F) != 0x7F else { return nil }
            return s & 0x7F
        }
    }

    /// Cleanup for every path: kills and reaps only this child.
    func cleanup() {
        if isRunning { kill(pid, SIGKILL) }
        wait()
    }
}

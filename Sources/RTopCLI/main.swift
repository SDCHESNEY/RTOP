import DarwinSupport
import Darwin
import Foundation
import MonitorCore
import MonitorDarwin
import TerminalUI

// Phase 0 spike entry point. Full option parsing arrives in Phase 1/4.

func printUsage() {
    print("""
    usage: rtop [--help] [--version] [--spike-native] [--spike-terminal]

      --spike-native    Phase 0: print one native-collection probe and exit.
      --spike-terminal  Phase 0: enter/restore terminal mode; press q or Ctrl-C.
    """)
}

func runNativeSpike() -> Int32 {
    do {
        let r = try NativeProbe.run()
        print("processes:        \(r.processCount)")
        print("self:             pid \(r.ownBSD.pid) ppid \(r.ownBSD.ppid) uid \(r.ownBSD.uid) name \(r.ownBSD.name)")
        print("self start:       \(r.ownBSD.startSeconds).\(String(format: "%06llu", r.ownBSD.startMicroseconds))")
        print("self path:        \(r.ownPath)")
        print("self rss/virt:    \(r.ownTask.residentBytes) / \(r.ownTask.virtualBytes) bytes, threads \(r.ownTask.threadCount)")
        print("self cpu time:    user \(r.ownTask.userTimeNanoseconds) ns, system \(r.ownTask.systemTimeNanoseconds) ns")
        print("logical CPUs:     \(r.logicalCPUCount)")
        print("physical memory:  \(r.physicalMemoryBytes) bytes")
        print("page size:        \(r.pageSizeBytes) bytes")
        print("vm pages:         free \(r.freePages), wired \(r.wiredPages), compressor \(r.compressorPages)")
        print("swap total:       \(r.swapTotalBytes.map(String.init) ?? "unavailable") bytes")
        print("boot time:        \(r.bootTime)")
        print("perf levels:      \(r.perfLevelCount.map(String.init) ?? "unavailable")")
        return 0
    } catch {
        FileHandle.standardError.write(Data("rtop: \(error)\n".utf8))
        return 1
    }
}

func runTerminalSpike() -> Int32 {
    var signalFD: Int32 = -1
    guard ds_signal_bridge_install(&signalFD).kind == DS_OK else {
        FileHandle.standardError.write(Data("rtop: cannot install signal bridge\n".utf8))
        return 1
    }
    defer { ds_signal_bridge_remove() }

    let session = TerminalSession()
    do { try session.enter() } catch {
        FileHandle.standardError.write(Data("rtop: \(error)\n".utf8))
        return 1
    }
    defer { session.restore() }

    func draw(_ message: String) {
        session.write("\u{1B}[2J\u{1B}[H\(message)")
    }
    draw("rtop terminal spike - press q or Ctrl-C to quit; resize the window to test SIGWINCH.\r\n")

    var fds = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
               pollfd(fd: signalFD, events: Int16(POLLIN), revents: 0)]
    while true {
        let n = poll(&fds, nfds_t(fds.count), -1)
        if n < 0 { if errno == EINTR { continue }; return 1 }

        if fds[1].revents & Int16(POLLIN) != 0 {
            var buf = [UInt8](repeating: 0, count: 16)
            let got = read(signalFD, &buf, buf.count)
            for b in buf.prefix(max(got, 0)) {
                switch Int32(b) {
                case SIGWINCH:
                    var ws = winsize()
                    _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws)
                    draw("resized: \(ws.ws_col)x\(ws.ws_row)\r\n")
                case SIGINT, SIGTERM, SIGHUP:
                    return 0
                default: break
                }
            }
        }
        if fds[0].revents & Int16(POLLIN | POLLHUP) != 0 {
            var buf = [UInt8](repeating: 0, count: 64)
            let got = read(STDIN_FILENO, &buf, buf.count)
            if got <= 0 { return 0 } // EOF
            // In raw mode Ctrl-C arrives as 0x03 rather than SIGINT.
            if buf.prefix(got).contains(where: { $0 == UInt8(ascii: "q") || $0 == 0x03 }) { return 0 }
        }
    }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "--help", "-h": printUsage(); exit(0)
case "--version": print("\(BuildInfo.productName) \(BuildInfo.version)"); exit(0)
case "--spike-native": exit(runNativeSpike())
case "--spike-terminal": exit(runTerminalSpike())
case nil: printUsage(); exit(2)
default:
    FileHandle.standardError.write(Data("rtop: unknown option \(args[0])\n".utf8))
    exit(2)
}

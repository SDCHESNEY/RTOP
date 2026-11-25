import Darwin
import DarwinSupport
import Foundation
import MonitorCore
import MonitorDarwin
import TerminalUI

func writeError(_ message: String) {
    FileHandle.standardError.write(Data("rtop: \(message)\n".utf8))
}

/// Runs the interactive monitor and returns the process exit code
/// (0 normal exit, 1 startup/runtime failure; usage errors are handled earlier).
@MainActor
func runMonitor(refreshMilliseconds: Int) async -> Int32 {
    // Suspension is disabled in the first release: raw mode already turns
    // Ctrl-Z into an ordinary byte, and ignoring SIGTSTP covers `kill -TSTP`.
    // A dead terminal must surface as a write error, not kill the process.
    signal(SIGTSTP, SIG_IGN)
    signal(SIGPIPE, SIG_IGN)

    var signalFD: Int32 = -1
    guard ds_signal_bridge_install(&signalFD).kind == DS_OK else {
        writeError("cannot install signal handlers")
        return 1
    }
    defer { ds_signal_bridge_remove() }

    let session = TerminalSession()
    do { try session.enter() } catch {
        writeError("\(error)")
        return 1
    }
    defer { session.restore() } // runs after the worker and input threads are joined (below)

    var state = AppState(
        terminalSize: session.size() ?? TerminalSize(columns: 80, rows: 24),
        refreshIntervalMilliseconds: refreshMilliseconds
    )
    state.ownPID = getpid()
    let controller = ProcessController()
    var renderer = ScreenRenderer()
    let renderOptions = RenderOptions.detect(environment: ProcessInfo.processInfo.environment)

    // All inputs funnel into one stream consumed on the main actor.
    let (actions, sink) = AsyncStream<Action>.makeStream()

    let worker = SamplingWorker { DarwinCollector() }
    worker.start()

    let pump = TerminalInputPump(signalFD: signalFD) { event in
        switch event {
        case .key(let key): sink.yield(.key(key))
        case .resize:
            sink.yield(.resize(TerminalSession.querySize(fd: STDOUT_FILENO) ?? TerminalSize(columns: 80, rows: 24)))
        case .terminate, .endOfInput: sink.yield(.terminate)
        }
    }
    pump.start()

    let forwarder = Task {
        for await event in worker.events {
            switch event {
            case .snapshot(let snapshot): sink.yield(.snapshot(snapshot))
            case .failed(let sequence, let message): sink.yield(.collectionFailed(sequence: sequence, message: message))
            }
        }
    }
    let detailForwarder = Task {
        for await event in worker.detailEvents {
            sink.yield(.detailsLoaded(generation: event.generation, details: event.details))
        }
    }
    let interval = Duration.milliseconds(refreshMilliseconds)
    let ticker = Task {
        while !Task.isCancelled {
            sink.yield(.tick) // first tick fires immediately
            try? await Task.sleep(for: interval)
        }
    }

    var exitCode: Int32 = 0
    func draw() -> Bool {
        let frame = renderer.frame(for: ProcessTableView.render(state, size: state.terminalSize, options: renderOptions))
        if session.write(frame) { return true }
        renderer.invalidate()
        return false
    }

    if !draw() { exitCode = 1 }
    if exitCode == 0 {
        loop: for await action in actions {
            for effect in Reducer.reduce(&state, action) {
                switch effect {
                case .requestRefresh: worker.requestRefresh()
                case .loadDetails(let identity, let generation):
                    worker.requestDetails(for: identity, generation: generation)
                case .sendSignal(let request):
                    // Synchronous on purpose: no suspension point between the
                    // controller's identity check and its kill call.
                    sink.yield(.signalResult(request: request, result: controller.send(request)))
                case .exit: break loop
                }
            }
            if !draw() {
                exitCode = 1 // terminal disconnected
                break
            }
        }
    }

    // Shutdown order: stop producers, join threads, then the deferred terminal restore.
    ticker.cancel()
    pump.stopAndJoin()
    worker.stopAndJoin()
    sink.finish()
    _ = await forwarder.value
    _ = await detailForwarder.value
    return exitCode
}

switch Options.parse(Array(CommandLine.arguments.dropFirst())) {
case .failure(let error):
    writeError("\(error)\n\n\(Options.usage())")
    exit(2)
case .success(.help):
    print(Options.usage())
    exit(0)
case .success(.version):
    print("\(BuildInfo.productName) \(BuildInfo.version)")
    exit(0)
case .success(.spikeNative):
    exit(runNativeSpike())
case .success(.spikeTerminal):
    exit(runTerminalSpike())
case .success(.run(let refresh)):
    exit(await runMonitor(refreshMilliseconds: refresh))
}

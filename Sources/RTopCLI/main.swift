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
func runMonitor(settings: Settings, configWarnings: [String], logger: FileLogger) async -> Int32 {
    let refreshMilliseconds = settings.refreshMilliseconds
    // Suspension is disabled in the first release: raw mode already turns
    // Ctrl-Z into an ordinary byte, and ignoring SIGTSTP covers `kill -TSTP`.
    // A dead terminal must surface as a write error, not kill the process.
    signal(SIGTSTP, SIG_IGN)
    signal(SIGPIPE, SIG_IGN)

    var signalFD: Int32 = -1
    guard ds_signal_bridge_install(&signalFD).kind == DS_OK else {
        writeError("cannot install signal handlers")
        logger.log(.error, "cannot install signal handlers")
        return 1
    }
    defer { ds_signal_bridge_remove() }

    let session = TerminalSession()
    do { try session.enter() } catch {
        writeError("\(error)")
        logger.log(.error, "cannot enter terminal mode: \(error)")
        return 1
    }
    defer { session.restore() } // runs after the worker and input threads are joined (below)

    var state = AppState(
        terminalSize: session.size() ?? TerminalSize(columns: 80, rows: 24),
        refreshIntervalMilliseconds: refreshMilliseconds,
        historyCapacity: settings.historySamples
    )
    state.ownPID = getpid()
    state.sortKey = settings.sortKey
    state.sortDescending = settings.descending
    state.normalizeCPU = settings.normalizeCPU
    if !configWarnings.isEmpty {
        state.messages.append(StatusMessage(kind: .configWarning, text: configWarnings.joined(separator: "; ")))
    }
    let controller = ProcessController()
    let renderOptions = RenderOptions.detect(
        environment: ProcessInfo.processInfo.environment, theme: settings.theme, color: settings.color)
    var renderer = ScreenRenderer(truecolor: renderOptions.color == .truecolor)

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
            case .failed(let sequence, let message):
                logger.log(.warning, "collection failed: \(message)", rateLimitKey: "collection-failed")
                sink.yield(.collectionFailed(sequence: sequence, message: message))
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

    if !draw() { exitCode = 1; logger.log(.error, "terminal write failed at startup") }
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
                logger.log(.error, "terminal write failed; exiting")
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
case .success(.generateCompletions(let shell)):
    print(OptionDocs.completions(shell: shell) ?? "", terminator: "")
    exit(0)
case .success(.generateMan):
    let date = Date().formatted(.iso8601.year().month().day())
    print(OptionDocs.manPage(version: BuildInfo.version, date: date), terminator: "")
    exit(0)
case .success(.spikeNative):
    exit(runNativeSpike())
case .success(.spikeTerminal):
    exit(runTerminalSpike())
case .success(.run(let request)):
    let home = FileManager.default.homeDirectoryForCurrentUser
    let loaded: LoadedConfiguration
    do {
        loaded = try ConfigLoader.load(explicitPath: request.configPath, defaultURL: ConfigLoader.defaultURL(home: home))
    } catch {
        writeError("\(error)")
        exit(2) // an explicit configuration file must exist and be valid
    }
    let settings = Settings.resolve(cli: request.settings, file: loaded.settings)

    let logger = FileLogger(directory: FileLogger.standardDirectory(home: home))
    logger.log(.info, "start \(BuildInfo.version) refresh=\(settings.refreshMilliseconds)ms theme=\(settings.theme.rawValue) color=\(settings.color.rawValue)")
    for warning in loaded.warnings { logger.log(.warning, warning) }
    let code = await runMonitor(settings: settings, configWarnings: loaded.warnings, logger: logger)
    logger.log(.info, "exit \(code)")
    logger.flush()
    exit(code)
}

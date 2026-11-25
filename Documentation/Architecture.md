# Architecture and Environment

## Recorded environment (Phase 0, development machine)

| Item | Value |
|---|---|
| Xcode | 27.2 (build 27B52) |
| Swift | 6.4.2 (swiftlang-6.4.2.1.9), language mode 6 |
| SDK | macOS 27.2 |
| Host OS | macOS 27.0.1, arm64 |
| Deployment target | macOS 26.0 (`minos 26.0` in the built binary) |
| Package minimums | `swift-tools-version: 6.2`, `.macOS(.v26)` (the newest Intel CI runner provides Xcode 26.6) |
| Architecture policy | arm64 is validated. x86_64 is built in CI only if a runner is available and is otherwise **unvalidated**. |

## CI runners

| Label | OS | Xcode | Architecture |
|---|---|---|---|
| `xcode-27` | macOS 27.0.1 | 27.2 (27B52), matches the development machine | arm64 |
| `macos-26-intel` | macOS 26 | 26.6 | x86_64 |

There is no macOS 27 Intel runner, so `macos-26-intel` is the newest available x86_64 environment. The "Record environment" step of each job logs the actual architecture and toolchain; confirm these from the first run.

## Decisions

- **Package layout.** SwiftPM package at the repository root, executable product `rtop` from target `RTopCLI`. Xcode opens `Package.swift` directly. The original `RTOP.xcodeproj` / `RTOP/main.swift` template is left in place, unused; remove it once the package workflow is accepted.
- **Dependency direction.** `MonitorCore` has no Darwin-specific code. `MonitorDarwin` and `TerminalUI` depend on `DarwinSupport` (C) and `MonitorCore`. Only `RTopCLI` wires them together.
- **Tests.** Swift Testing (`import Testing`). The specification says XCTest; Swift Testing was used instead because it is the current framework for new unit tests and runs under `swift test` and Xcode. Pseudo-terminal and signal tests are serialized.
- **Sandbox.** No App Sandbox, no entitlements, no helper.
- **Suspend (Ctrl-Z).** Not implemented. Raw mode clears `ISIG`, so Ctrl-Z arrives as a byte and is ignored. First release will keep suspension disabled unless Phase 4 adds restore/redraw.
- **Spike entry points.** `--spike-native` and `--spike-terminal` in `RTopCLI/main.swift` are Phase 0 scaffolding and are replaced by real option parsing in Phase 1.

## Debugging workflow

Run the actual TUI from a real terminal. To step through it in Xcode, launch `rtop` in a terminal and use Debug > Attach to Process.

## Phase 1 design notes

- **Data flow.** `DarwinCollector` (worker thread) → `SamplingWorker` (`AsyncStream`, newest-only) → one `Action` stream on the main actor → `Reducer` → `ProcessTableView` → `ScreenRenderer` → `TerminalSession.write`. The reducer is pure and returns `[Effect]`; `main.swift` runs the effects.
- **Threads.** Sampler thread (owns the non-`Sendable` collector, created on that thread), input thread (stdin + signal pipe, owns the decoder), and the main actor. Ticks are produced by a `Task` and turn into `requestRefresh()`; a request while a refresh is running or queued is dropped, so a slow collector cannot build a backlog.
- **`@unchecked Sendable`.** Used for `SamplingWorker`, `TerminalInputPump`, and `ManualClock` only. Each documents its invariant: all mutable state is guarded by one lock/condition (or confined to one thread).
- **Shutdown order.** Cancel ticker → join input thread → join sampler thread → finish streams → restore terminal (deferred) → remove signal handlers.
- **Selection rule.** Selection follows process identity. If the selected process disappears, selection moves to the first surviving row after its old position, else the nearest surviving row before it, else the first row. A reused PID with a new start time is a different process and is never inherited.
- **Partial rows.** On this machine `proc_pidinfo` returns EPERM for roughly a third of processes (other users' / system processes) while `proc_pidpath` still works. Those rows are kept: identity is PID-only, name comes from the executable path, user/parent/state are unavailable, and CPU is unavailable because a PID-only identity cannot be baselined safely. Phase 3 may add a `sysctl(KERN_PROC_PID)` fallback for start time and parent.
- **Default order.** Rows are sorted by PID ascending until Phase 2 adds sorting.
- **Display width.** `DisplayWidth` approximates East Asian Width plus zero-width combining marks; ambiguous-width characters count as one column. Emulators differ, so wide-character alignment can be off by a column in some terminals.
- **Suspend.** Ctrl-Z is an ordinary byte in raw mode and is ignored; SIGTSTP is ignored so `kill -TSTP` cannot leave the terminal raw. Documented and intentional for the first release.
- **Escape key.** A lone ESC resolves as Escape after 40 ms. In Phase 1 Escape quits (no modal or filter context exists yet).
- **Exit codes.** 0 normal exit (including q, Ctrl-C, SIGTERM, SIGHUP, stdin EOF), 1 startup/runtime failure (not a terminal, signal bridge failure, terminal disconnect), 2 invalid command line.
- **End-to-end check.** `Scripts/pty_lifecycle_check.py` and `Scripts/pty_idle_check.py` drive the real binary in a pseudo-terminal.

## Phase 2 design notes

- **Presentation vs. collection.** `AppState.snapshot`/`rows`/histories are what is *presented*. While paused, new snapshots only update `pendingSnapshot` and `lastAcceptedSequence`; resume presents the newest one. Rows are always `filter → sort` of the presented snapshot, rebuilt in one place (`Reducer.rebuildRows`), and the selection-loss rule from Phase 1 applies to filtering as well as exits.
- **Filter editing is a reducer context.** While `filterEditor` is non-nil, printable keys are text (including `q`, `k`, `s`, `r`, space); only Ctrl-C quits, Esc cancels, arrows still navigate.
- **Layout.** `ProcessTableLayout.overviewRows` is 7 at ≥60x20 and 1 (title only) below that, so the 20x5 and 40x8 layouts are unchanged apart from the sort arrow. At ≥100 columns the table gains PPID and sparklines widen to 60 samples.
- **Native adapters.** `NativeProcessAPI` gained memory, swap, physical memory, uptime, topology, and pressure with default "unsupported" implementations, so existing fakes keep working. Topology and physical memory are cached by `DarwinCollector`. `MemoryPressureMonitor` is `@unchecked Sendable`: its reading is guarded by one lock.
- **Rendering options.** `RenderOptions` (mono/256-color, ASCII glyphs) is detected from environment hints only (`NO_COLOR`, `TERM`, locale) in `main.swift`; Phase 4 adds `--color`/`--theme`. Bars, sparklines, and the sort arrow have ASCII fallbacks; the other glyphs (`—`, `…`, `·`) do not.
- **Stale indicator.** The reducer has no clock, so staleness counts `.tick` actions since the last accepted snapshot.

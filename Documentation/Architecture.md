# Architecture and Environment

## Recorded environment (Phase 0, development machine)

| Item | Value |
|---|---|
| Xcode | 27.2 (build 27B52) |
| Swift | 6.4.2 (swiftlang-6.4.2.1.9), language mode 6 |
| SDK | macOS 27.2 |
| Host OS | macOS 27.0.1, arm64 |
| Deployment target | macOS 14.0 (`minos 14.0` in the built binary) |
| Architecture policy | arm64 is validated. x86_64 is built in CI only if a runner is available and is otherwise **unvalidated**. |

CI runner labels in `.github/workflows/ci.yml` are provisional: confirm the real architecture from the "Record environment" step of the first run and update this table. The macOS 14 deployment target has been compiled against, **not runtime-tested** on macOS 14.

## Decisions

- **Package layout.** SwiftPM package at the repository root, executable product `rtop` from target `RTopCLI`. Xcode opens `Package.swift` directly. The original `RTOP.xcodeproj` / `RTOP/main.swift` template is left in place, unused; remove it once the package workflow is accepted.
- **Dependency direction.** `MonitorCore` has no Darwin-specific code. `MonitorDarwin` and `TerminalUI` depend on `DarwinSupport` (C) and `MonitorCore`. Only `RTopCLI` wires them together.
- **Tests.** Swift Testing (`import Testing`). The specification says XCTest; Swift Testing was used instead because it is the current framework for new unit tests and runs under `swift test` and Xcode. Pseudo-terminal and signal tests are serialized.
- **Sandbox.** No App Sandbox, no entitlements, no helper.
- **Suspend (Ctrl-Z).** Not implemented. Raw mode clears `ISIG`, so Ctrl-Z arrives as a byte and is ignored. First release will keep suspension disabled unless Phase 4 adds restore/redraw.
- **Spike entry points.** `--spike-native` and `--spike-terminal` in `RTopCLI/main.swift` are Phase 0 scaffolding and are replaced by real option parsing in Phase 1.

## Debugging workflow

Run the actual TUI from a real terminal. To step through it in Xcode, launch `rtop` in a terminal and use Debug > Attach to Process.

# rtop

A terminal-based system monitor for macOS written in Swift. **Status: Phase 0 (setup and native/terminal spikes).** There is no monitor UI yet; see `docs/implementation.md` for the plan and `docs/technicalspecification.md` for the specification.

## Build and test

Xcode: open `Package.swift` (File > Open), select the `rtop` scheme, build with Cmd-B, run tests with Cmd-U.

Command line:

```sh
swift build
swift test
swift build -c release
```

## Phase 0 spikes

```sh
.build/debug/rtop --spike-native     # one native collection probe, then exits
.build/debug/rtop --spike-terminal   # raw mode + alternate screen; q or Ctrl-C quits
```

Run the terminal spike from a real terminal (Terminal.app, iTerm2). Xcode's debug console is not a terminal. To debug interactively, start the binary in a terminal and attach Xcode's debugger to the process.

## If a terminal is left in a bad state

If `rtop` is killed uncatchably (SIGKILL, power loss) the terminal may remain in raw mode. Recover with:

```sh
stty sane; printf '\033[?1049l\033[?25h\033[0m'; reset
```

## Documentation

- `Documentation/Architecture.md` — environment, target layout, decisions
- `Documentation/SDKInteropReport.md` — native API findings

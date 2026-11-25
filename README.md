# rtop

A terminal-based system monitor for macOS written in Swift. **Status: Phase 2 (overview panels, sorting, filtering, history, pause; `v0.2` in progress).** See `docs/implementation.md` for the plan and `docs/technicalspecification.md` for the specification.

## Build and test

Xcode: open `Package.swift` (File > Open), select the `rtop` scheme, build with Cmd-B, run tests with Cmd-U.

Command line:

```sh
swift build
swift test
swift build -c release
```

## Running

Run `rtop` from a real terminal (Terminal.app, iTerm2); Xcode's debug console is not a terminal.

```sh
.build/debug/rtop                      # interactive process table
.build/debug/rtop --refresh-ms 500     # refresh interval, minimum 250
.build/debug/rtop --help
```

| Key | Action |
|---|---|
| `q`, Ctrl-C, Esc | Quit |
| Up/Down, `j`/`k` | Move selection |
| Page Up/Page Down | Move by a page |
| Home/End | First/last row |

Unavailable values show `—` (never zero). CPU% needs two samples, so it fills in after the first refresh. Ctrl-Z (suspend) is disabled in this release.

End-to-end terminal checks: `python3 -I Scripts/pty_lifecycle_check.py .build/debug/rtop`.

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
- `Documentation/Metrics.md` — metric units, conventions, and non-claims

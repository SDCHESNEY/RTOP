# rtop

A terminal-based system monitor for macOS written in Swift. **Status: Phase 3 (safe process controls`v0.3`) completed.** See `docs/implementation.md` for the plan and `docs/technicalspecification.md` for the specification.

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
| `q`, Ctrl-C | Quit |
| Esc | Close the innermost dialog or pane; quit if none is open |
| Up/Down, `j`/`k` | Move selection |
| Page Up/Page Down, Home/End | Move by a page / first and last row |
| `s`, `r` | Cycle sort field / reverse |
| `/` | Edit the filter (`pid:`, `user:`, `path:`) |
| Space | Pause/resume the display |
| `t` | Toggle the process tree |
| `d`, Enter | Show details of the selected process |
| `x` | Send a signal (SIGTERM by default; asks for confirmation) |
| `?` | Help |

Signalling never happens without an explicit confirmation; root-owned and system processes need a second `y`. PID 1, `rtop` itself, and processes whose start time cannot be read are refused. See `Documentation/Permissions.md`.

Unavailable values show `—` (never zero). CPU% needs two samples, so it fills in after the first refresh. Ctrl-Z (suspend) is disabled in this release.

End-to-end terminal checks: `python3 -I Scripts/pty_lifecycle_check.py .build/debug/rtop`.
## If a terminal is left in a bad state

If `rtop` is killed uncatchably (SIGKILL, power loss) the terminal may remain in raw mode. Recover with:

```sh
stty sane; printf '\033[?1049l\033[?25h\033[0m'; reset
```

## Documentation

- `Documentation/Architecture.md` — environment, target layout, decisions
- `Documentation/SDKInteropReport.md` — native API findings
- `Documentation/Metrics.md` — metric units, conventions, and non-claims

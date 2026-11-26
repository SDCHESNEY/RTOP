# rtop

A terminal system monitor for macOS, written in Swift with no third-party dependencies. It shows processes, CPU, memory, swap, load, and memory pressure in a keyboard-driven full-screen terminal UI, and can send signals to processes after an explicit confirmation.

**Status:** Phases 0–4 of the plan are implemented. `v1.0` is not tagged yet because manual release validation (three terminals, Instruments runs, signing, Homebrew) is still open; see `Documentation/ReleaseChecklist.md`. There are no published binaries, so you build from source.

- Plan and phase gates: [`Documentation/implementation.md`](Documentation/implementation.md)
- Specification: [`Documentation/technicalspecification.md`](Documentation/technicalspecification.md)
- License: MIT, see [`LICENSE`](LICENSE)

## Requirements

- A Mac running **macOS 26 or newer** (the package's deployment target).
- **Xcode 26 or newer** (Swift 6.2 toolchain, `swift-tools-version: 6.2`) or the matching Command Line Tools. Check with `swift --version` and `xcodebuild -version`.
- A real terminal such as Terminal.app or iTerm2. Xcode's debug console is not a terminal, so `rtop` will refuse to start there.
- No administrator rights are needed. See [Permissions](#permissions-and-what-you-can-see).

## Get the source and build

```sh
git clone https://github.com/SDCHESNEY/RTOP.git
cd RTOP

swift build -c release        # optimized binary at .build/release/rtop
swift test                    # optional: run the test suite
```

Run it:

```sh
.build/release/rtop
```

To use it from anywhere, copy the binary onto your `PATH`:

```sh
sudo install -m 755 .build/release/rtop /usr/local/bin/rtop
rtop --version
```

(Any directory on your `PATH` works; `~/bin` needs no `sudo`.)

### Using Xcode instead

1. `File > Open…` and choose `Package.swift` in the cloned folder.
2. Select the `rtop` scheme and build with Cmd-B; run the tests with Cmd-U.
3. To run, build, then start the binary from a real terminal. The product path is shown under `Product > Show Build Folder in Finder`. To debug, start `rtop` in a terminal and use `Debug > Attach to Process > rtop`.

### Packaging an archive

```sh
Scripts/package.sh                      # dist/rtop-<version>-arm64.tar.gz, unsigned
ARCHS="arm64 x86_64" Scripts/package.sh # universal binary (x86_64 is unvalidated unless you run it on Intel)
```

The archive contains `rtop`, the man page, and shell completions. Signing and notarization happen only if you set `DEVELOPER_ID` (and `NOTARY_PROFILE`); otherwise the archive is unsigned.

### Man page and shell completions

Both are generated from the program's option table:

```sh
.build/release/rtop --generate-man > rtop.1 && man ./rtop.1

# zsh (put the file in a directory on your fpath), bash, or fish
.build/release/rtop --generate-completions zsh  > _rtop
.build/release/rtop --generate-completions bash > rtop.bash     # then: source rtop.bash
.build/release/rtop --generate-completions fish > ~/.config/fish/completions/rtop.fish
```

## Using rtop

Start it in a terminal at least 20 columns by 5 rows (80×24 or larger is comfortable; 120×40 shows more columns and longer graphs):

```sh
rtop                                   # defaults: 1 s refresh, sorted by PID
rtop --refresh-ms 500                  # faster refresh (minimum 250)
rtop --sort cpu --descending           # busiest processes first
rtop --sort memory --descending --normalize-cpu
rtop --theme light --color 256         # for a light terminal background
rtop --theme mono                      # no color at all
NO_COLOR=1 rtop                        # same, via the environment
rtop --help                            # options; --version prints the version
```

### The screen

- **Top (overview, shown at 60×20 or larger):** title with process count, uptime and load averages; CPU bar with a history sparkline; one bar per core; memory bar ("approx. used" = wired + active + compressor) with its history; memory categories; swap; and memory pressure.
- **Middle:** the process table with PID, name, user, CPU%, memory (resident), and state columns, plus PPID on wide terminals. The column header shows the sort field and direction. Narrow terminals drop low-priority columns.
- **Bottom:** a footer with key hints for whatever is open, or a status message.
- `PAUSED` and `STALE` badges appear at the top right when the display is paused or no new data has arrived for several refreshes.

A `—` means the value could not be read (never "zero"). CPU% needs two samples, so it fills in after the first refresh. By default 100% is one fully busy core, so a multithreaded process can exceed 100%; `--normalize-cpu` divides by the logical CPU count and relabels the column `NCPU%`.

### Keys

Press `?` inside `rtop` for the help overlay, which is generated from the same table the program uses.

| Key | Action |
|---|---|
| `q`, Ctrl-C | Quit |
| Esc | Close the innermost dialog or pane; quit if none is open |
| Up/Down, `j`/`k` | Move the selection |
| Page Up/Page Down, Home/End | Move by a page / jump to first or last |
| `s` | Cycle the sort field (PID, name, user, CPU, memory, state) |
| `r` | Reverse the sort order |
| `/` | Edit the filter (see below) |
| Space | Pause/resume the display (sampling continues underneath) |
| `t` | Toggle the process tree |
| `d`, Enter | Show details of the selected process; Esc or `d` closes |
| `x` | Send a signal to the selected process (asks first) |
| `?` | Help |

Everything is keyboard-only; there is no mouse support. Ctrl-Z (suspend) is disabled.

### Filtering

Press `/` and type; the list narrows as you type. Space, `s`, `r`, and other letters are plain text while the filter editor is open. Enter keeps the filter, Esc restores the previous one, Ctrl-U clears the text. An invalid expression keeps the last valid filter and shows the error.

| Term | Matches |
|---|---|
| `safari` | process names containing it (case-insensitive) |
| `pid:412` | exactly that PID |
| `user:root`, `user:501` | that user name or numeric UID |
| `path:/Applications` | executable path containing the text |

Several terms separated by spaces must all match, for example `user:root path:/usr/libexec`.

### Details and the process tree

`d` or Enter opens a pane for the selected process: path, command line (arguments only, never environment), parent, user, start time, CPU, resident and virtual size, and threads. The pane follows the selection with Up/Down. Fields that cannot be read say why. Command lines are held in memory only and are never logged.

`t` shows processes as a parent/child tree rooted at PID 1; processes with a missing or reused parent are grouped under "Unattached". Sorting applies among siblings, and with a filter active, matches are shown with their ancestors dimmed.

### Sending a signal

1. Select a process and press `x`.
2. Choose the signal with Left/Right (SIGTERM is the default; SIGINT, SIGHUP, SIGSTOP, SIGCONT, and SIGKILL are available). Changing the signal resets any confirmation already given.
3. Press `y` or Enter to confirm, `n` or Esc to cancel. Root-owned and system processes (`/System`, `/usr`, `/sbin`) need a second `y`; Enter does not satisfy that stage.

`rtop` refuses PID 1, itself, invalid PIDs, and any process whose start time cannot be verified. It re-checks the process's identity immediately before sending. "Signal sent" means the OS accepted the signal, not that the process has exited; a small race between the check and delivery remains and is documented in `Documentation/Permissions.md`.

### Permissions and what you can see

`rtop` runs unprivileged and does not use sudo or entitlements. macOS hides some details of other users' and system processes; those rows appear with `—` and the footer counts them as "limited". You can only signal processes you are allowed to signal; otherwise you get a permission message.

## Configuration

Settings can come from the command line, a JSON file, or built-in defaults, in that order of precedence.

| Option | Meaning |
|---|---|
| `--refresh-ms N` | Refresh interval, default 1000, minimum 250 |
| `--sort KEY` | `pid` (default), `name`, `user`, `cpu`, `memory`, `status` |
| `--descending` | Start with a descending sort |
| `--theme NAME` | `dark` (default), `light`, `mono` |
| `--color MODE` | `auto` (default), `never`, `256`, `truecolor`; a non-empty `NO_COLOR` always disables color |
| `--normalize-cpu` | Process CPU as a share of all logical CPUs |
| `--history-samples N` | Graph history length, 1–3600, default 60 |
| `--config PATH` | Use this file; it must exist and be valid |
| `--no-mouse` | Accepted; mouse support is not shipped |
| `--help`, `--version` | Print and exit without entering terminal mode |

The default config file is `~/Library/Application Support/rtop/config.json`. `rtop` never creates it; make the folder and file yourself:

```sh
mkdir -p ~/Library/Application\ Support/rtop
cat > ~/Library/Application\ Support/rtop/config.json <<'JSON'
{
  "sort": "cpu",
  "descending": true,
  "theme": "dark",
  "historySamples": 120
}
JSON
```

A missing default file is normal. An invalid default file shows a `config:` warning in the footer and uses defaults. A missing or invalid `--config` file exits with status 2. Unknown keys produce a warning listing the valid ones. All keys, ranges, and the color rules are in [`Documentation/Configuration.md`](Documentation/Configuration.md).

Exit status: `0` normal, `1` startup or runtime failure (including stdin or stdout not being a terminal), `2` invalid options or configuration.

## Logging and privacy

`~/Library/Logs/rtop/rtop.log` records start/exit, configuration warnings, and rate-limited collection failures. The directory is owner-only (0700), the file is 0600, and it rotates at 256 KiB keeping three older files. It never contains command lines, environment variables, or process listings. `rtop` makes no network connections.

## Troubleshooting

- **"standard input and output must both be terminals"**: run `rtop` directly in Terminal.app or iTerm2, not through a pipe, redirect, or Xcode's console.
- **Screen looks garbled or has no color**: try `--color 256` (or `--theme mono`), and make sure your locale is UTF-8 (otherwise ASCII glyphs are used automatically).
- **Terminal left in a bad state** (after an uncatchable kill such as SIGKILL or power loss, the terminal can stay in raw mode):

  ```sh
  stty sane; printf '\033[?1049l\033[?25h\033[0m'; reset
  ```

- **Build fails with a toolchain or SDK error**: confirm macOS 26+ and Xcode 26+; select it with `sudo xcode-select -s /Applications/Xcode.app`.

## Development

```sh
swift build -Xswiftc -warnings-as-errors -Xcc -Werror   # what CI runs
swift test                                              # unit, integration, and pty-based tests
python3 -I Scripts/pty_lifecycle_check.py .build/debug/rtop   # end-to-end terminal lifecycle
python3 -I Scripts/pty_idle_check.py .build/debug/rtop        # terminal restoration and idle CPU
```

Layout: `Sources/MonitorCore` (pure models, reducer, config), `Sources/MonitorDarwin` (native collection, process control, logging), `Sources/TerminalUI` (terminal and rendering), `Sources/DarwinSupport` (C boundary), `Sources/RTopCLI` (entry point).

## Documentation

- [`Documentation/implementation.md`](Documentation/implementation.md): implementation plan and phase gates
- [`Documentation/technicalspecification.md`](Documentation/technicalspecification.md): specification
- [`Documentation/Architecture.md`](Documentation/Architecture.md): environment, layout, decisions
- [`Documentation/Configuration.md`](Documentation/Configuration.md): config schema, precedence, color rules
- [`Documentation/Metrics.md`](Documentation/Metrics.md): units, conventions, non-claims
- [`Documentation/Permissions.md`](Documentation/Permissions.md): visibility and signalling behavior
- [`Documentation/SDKInteropReport.md`](Documentation/SDKInteropReport.md): native API findings
- [`Documentation/Performance.md`](Documentation/Performance.md): measured costs and open measurements
- [`Documentation/ReleaseChecklist.md`](Documentation/ReleaseChecklist.md): packaging, signing, manual test matrix
- [`CHANGELOG.md`](CHANGELOG.md)

## License

[MIT](LICENSE). Free to use, copy, modify, and distribute under the terms in that file.

# Changelog

## Unreleased

### Phase 2 — overview, sorting, filtering, history
- Memory categories (active, inactive, wired, compressor, free, purgeable, speculative, file-backed), swap, physical memory, uptime, and an "Approx. used" headline (wired + active + compressor) with checked arithmetic.
- Memory pressure from the dispatch memory-pressure source: `unknown` until the first notification, last state kept with its age.
- Core topology (`hw.perflevel*`) read once; counts reported separately, per-core bars stay unclassified.
- `ProcessSort` (`s` cycles key, `r` reverses; missing values last; PID/start tie-break) and `ProcessFilter` (`/` live editor; `pid:`/`user:`/`path:`; invalid input keeps the last valid filter, Esc restores).
- `HistoryBuffer` ring buffers (default 60) behind CPU and memory sparklines; Space pauses presentation while sampling continues.
- Overview panels at ≥60x20, extra PPID column and wider histories at ≥100 columns, ASCII glyph fallback, optional 256-color bars (`NO_COLOR` aware).
- `Documentation/Metrics.md` extended with memory, pressure, topology, sort, filter, and pause definitions.

### Phase 1 — read-only foundation
- Domain models with explicit availability (`Availability`, `ProcessIdentity` = PID + start time) and pure CPU arithmetic (process and host).
- `DarwinCollector`: per-PID BSD/task/path reads, partial rows for restricted processes, aggregated warnings, bounded user-name cache.
- `SamplingWorker`: one refresh in flight, newest-only delivery, joinable shutdown.
- Pure `Reducer`/`AppState`: identity-based selection, scrolling, stale-snapshot rejection.
- Terminal backend: incremental `InputDecoder`, input/signal pump, `CellBuffer`, diffing `ScreenRenderer`, text sanitizer, display widths.
- Process table view (PID, name, user, CPU%, memory, state) with priority column dropping and a minimal 20x5 layout.
- `rtop` now runs the monitor; `--refresh-ms` (validated, minimum 250), `--help`, `--version`; exit codes 0/1/2.
- Metric definitions in `Documentation/Metrics.md`; pty end-to-end scripts in `Scripts/`.

### Phase 0 — setup and spikes
- Swift package with targets `RTopCLI`, `MonitorCore`, `MonitorDarwin`, `TerminalUI`, `DarwinSupport` (C) and per-module test targets.
- C boundary spike for libproc, Mach CPU/VM, sysctl and the signal self-pipe.
- Terminal session proof of concept (`rtop --spike-terminal`) and native probe (`rtop --spike-native`).
- SDK interoperability report, architecture/environment notes, CI workflow.

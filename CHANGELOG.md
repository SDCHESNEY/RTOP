# Changelog

## Unreleased

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

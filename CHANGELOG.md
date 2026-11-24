# Changelog

## Unreleased

### Phase 0 — setup and spikes
- Swift package with targets `RTopCLI`, `MonitorCore`, `MonitorDarwin`, `TerminalUI`, `DarwinSupport` (C) and per-module test targets.
- C boundary spike for libproc, Mach CPU/VM, sysctl and the signal self-pipe.
- Terminal session proof of concept (`rtop --spike-terminal`) and native probe (`rtop --spike-native`).
- SDK interoperability report, architecture/environment notes, CI workflow.

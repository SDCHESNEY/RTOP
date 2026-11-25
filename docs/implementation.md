# Implementation Plan: `rtop` — Native macOS Terminal System Monitor (Swift)

**Source of truth:** `technicalspecification.md` (referred to below as "the spec"; section references are written as §N).
**Audience:** a single developer working in Xcode.
**Status:** Plan only. Effort figures are the spec's planning estimates (§16), to be re-estimated after Phase 0.

## 0. How to Use This Plan

- Phases map to the spec's phases (0–4) and release tags `v0.1`, `v0.2`, `v0.3`, `v1.0`.
- Each phase is broken into **work packages (WP)**. Each WP lists tasks, the files it touches, tests, and an exit check.
- Each phase ends with a **gate**: every checkbox must pass (or be explicitly recorded as unvalidated) before the next phase starts. Do not begin optional scope (extra panels, mouse polish) before the v1.0 gate.
- Work in dependency order inside a phase; the dependency graph in §0.2 shows what can run in parallel.
- Prefer pure, testable logic first (MonitorCore), then adapters (MonitorDarwin, TerminalUI), then wiring (RTopCLI).

### 0.1 Cross-Cutting Rules (apply to every phase)

| Rule | Source |
|---|---|
| Swift 6 language mode, strict concurrency, warnings as errors in CI. No `@unchecked Sendable` without a documented ownership invariant. | §3, §4.2 |
| Reducer is the only state mutation point; renderer is pure; collector never touches terminal or state. | §4.1, §5.4 |
| Unavailable ≠ zero. Use an explicit availability type with a reason. | §5.3 |
| All OS-derived strings are sanitized before reaching the screen. | §7.3 |
| Dependency-inject collector, clock, process controller, terminal sink, and native adapters. | §11.1 |
| Never log command lines, environment, or full process listings by default. | §10.4 |
| Tests may signal only child processes the test itself spawned. | §11.1 |
| No unsupported exactness claims (Activity Monitor parity, topology, pressure, signal atomicity). | §15 |
| Write the metric/permission docs alongside the code that implements them, not at the end. | §15 |

### 0.2 Dependency Overview

```text
Phase 0: Package/CI ──► C boundary spike ──► Terminal spike
              │
Phase 1: Models ─► Availability ─► Collector (proc) ─► Sampler/worker ─► Store/Reducer ─► Renderer ─► Terminal lifecycle ─► main wiring
Phase 2: CPU/Mem math ─► Topology ─► Sort/Filter ─► History ─► Overview panels ─► Goldens ─► Reference comparison
Phase 3: Details ─► Tree ─► Controller ─► Confirmation reducer ─► Modal UI ─► Child-process integration tests
Phase 4: Config/CLI ─► Themes ─► Hardening ─► Profiling ─► Packaging ─► Release matrix
```

Parallelizable inside Phase 1/2: Models/Reducer/Sort/Filter (pure) can proceed while the Darwin collector and TerminalUI are built.

---

## Phase 0 — Xcode Setup and Native API Spike (≈1–2 days)

**Goal:** a building, testing, CI-covered package; proof that the riskiest native and terminal pieces work; recorded environment facts.

### WP0.1 — Package and Xcode project structure
Tasks:
1. Reconcile the current Xcode project (`RTOP/RTOP/main.swift`, product `RTOP`) with the spec's SwiftPM layout (§4.3). Decision to record in `Documentation/Architecture.md`: either (a) convert to a Swift package opened in Xcode (spec default), or (b) keep the Xcode project and add local package targets. Prefer (a) with executable product named `rtop`.
2. Create `Package.swift` with targets: `RTopCLI` (executable), `MonitorCore`, `MonitorDarwin`, `TerminalUI`, `DarwinSupport` (C), and test targets `MonitorCoreTests`, `MonitorDarwinTests`, `TerminalUITests`.
3. Set platform `.macOS(.v14)`, `swiftLanguageModes: [.v6]`, and strict concurrency; add `-warnings-as-errors` for project targets in CI only (not for local dev).
4. Dependency rules: `MonitorCore` imports only Foundation (no Darwin-specific calls); `TerminalUI` depends on `MonitorCore` types for rendering; `MonitorDarwin` depends on `DarwinSupport`; `RTopCLI` is the only target that wires everything.
5. Keep App Sandbox disabled; no entitlements (§3.1.6).
6. Add `README.md` skeleton, `CHANGELOG.md`, `Documentation/` stubs.

Exit check: Xcode builds `rtop`, `swift build` works from CLI, an empty XCTest per test target runs.

### WP0.2 — Record environment
- Write exact Xcode, SDK, Swift compiler versions, deployment target, and architecture policy into `Documentation/Architecture.md` ("Environment" section).
- Identify CI runner labels and their real architectures; record them (do not assume) (§3.1, §11.4).

### WP0.3 — Native API spike (C boundary)
Tasks (spike code may be throwaway but findings are recorded):
1. Declare in `DarwinSupport.h` minimal wrappers for: `proc_listpids`, `proc_pidinfo` (BSD info, task info), `proc_pidpath`, `host_processor_info`, `host_statistics64`, `sysctl`/`sysctlbyname` reads (`hw.memsize`, `kern.boottime`, `vm.swapusage`, `hw.perflevel*`).
2. Verify against SDK headers: struct sizes, return-value contracts (bytes vs elements), link settings, and ownership of Mach-returned buffers (`vm_deallocate` for `host_processor_info` output).
3. Confirm a loop of N=1,000 refreshes does not leak (Instruments Leaks/Allocations).
4. Confirm process enumeration works unprivileged and what fields become unavailable for other users' processes.

Deliverable: `Documentation/SDKInteropReport.md` — table of each API, header, ownership rule, size check, error behavior, unprivileged behavior.

### WP0.4 — Terminal proof of concept
Tasks:
1. Minimal `TerminalSession`: `isatty` checks, save `termios`, enter raw mode, alternate screen, hide cursor, restore everything.
2. Verify in Terminal.app and iTerm2: restore on `q`, on Ctrl-C, on SIGTERM.
3. Prove the self-pipe signal bridge pattern in C (handler does only `write` to nonblocking pipe).
4. Document how to run: build in Xcode, run in a real terminal; attach debugger to the process (§3.1.7–8).

### WP0.5 — CI
- GitHub Actions (or equivalent) job: build debug, run tests, build release, Swift 6 strict concurrency with warnings-as-errors.
- Archive test results/coverage artifacts. Mark any unavailable architecture as "unvalidated".

### Phase 0 Gate
Status: implemented; items marked *partial* or *open* still need a human or CI run.

- [x] Package builds and tests run with the Xcode toolchain (`swift build`, `swift test`: 15 tests passing). *Partial:* not yet opened in the Xcode GUI, and XCTest was replaced by Swift Testing (see `Documentation/Architecture.md`)
- [x] Toolchain/SDK/deployment/arch recorded (`Documentation/Architecture.md`). CI runner architectures still to be confirmed from the first CI run
- [x] Process IDs, physical memory, host CPU counters read; `leaks` reports 0 leaks. *Partial:* Instruments Allocations run still open
- [x] SDK interop report written (`Documentation/SDKInteropReport.md`)
- [ ] Terminal PoC restores state in Terminal.app and iTerm2. *Open:* verified through pseudo-terminal tests and a scripted pty run of the real binary (q, Ctrl-C, SIGTERM, SIGHUP, resize); the manual run in both real terminals is still needed (`rtop --spike-terminal`)
- [x] No helper, entitlement workaround, or third-party runtime
- [ ] **Re-estimate Phases 1–4** and update this document. *Open:* pending review of the report and the manual terminal check

---

## Phase 1 — Read-Only Foundation (`v0.1`, ≈5–7 days)

**Goal:** a working process table with resilient collection, responsive input, correct terminal restoration.

### WP1.1 — Domain models (`MonitorCore/Models.swift`)
- `Availability<T>` (value or `Unavailable(reason)`), with reasons: permissionDenied, processExited, unsupported, notYetSampled, malformed, collectionFailed (§5.3).
- `ProcessIdentity` (pid + high-resolution start timestamp, optional start), `ProcessSummary`, `ProcessStatus` (with `.unknown`), `Snapshot`, `CPUReading`, `MemoryReading`, `SwapReading`, `LoadAverage`, `CollectionWarning` (bounded, aggregated) (§5.1–5.2).
- All `Sendable`, immutable, `Equatable`.
Tests: identity equality (same PID, different start ≠ same), codable not required.

### WP1.2 — Collector protocol and fakes
- `protocol SystemCollector: Sendable { func collect() throws -> Snapshot }` (or equivalent) plus `Clock` abstraction (monotonic).
- `FakeCollector` scripted from arrays; used for sampler and reducer tests.

### WP1.3 — `DarwinSupport` C boundary
- Implement the validated wrappers from the spike. Export owned records (fixed-size structs) to Swift; Swift copies into owned values.
- Bounded retry for `proc_listpids` growth; zero-length and allocation-failure paths; capture `errno` immediately; Mach status separate.
- Bounded, lossy string decoding (invalid UTF-8 → replacement).
- Header is the only declaration site (§4.4).

### WP1.4 — Process sampler (`MonitorDarwin/ProcessSampler.swift`)
- Enumerate PIDs → per-PID BSD info + task info + path. Any per-PID failure yields a partial row with reasons; process-exit mid-read is silent.
- UID → user name cache (bounded lifetime, resolved outside render path; thread-safe `getpwuid_r`).
- Native-status → `ProcessStatus` conservative mapping.
- Warnings aggregated into counts (no per-process message flood).
Tests: integration against current process and an owned child; mocked failure injection via adapter protocol.

### WP1.5 — CPU sampler (process + host)
- Per-identity cumulative counters, monotonic elapsed delta, unit conversion documented in `Documentation/Metrics.md`.
- First observation → `.unavailable(.notYetSampled)`; new process starts own baseline; changed start time invalidates; counter reset/nonpositive elapsed invalidates (§6.2).
- Pure arithmetic in `MonitorCore` (testable without FFI): `CPUMath.processPercent(...)`, `CPUMath.hostBusy(...)`.
- Host: aggregate via summed deltas, not mean of cores. Per-core readings stored (display in Phase 2).
Tests: first sample, zero elapsed, reset, wraparound, CPU-count change, overflow-safe math.

### WP1.6 — Sampling worker and concurrency
- Dedicated serial queue/thread owning the collector; at most one refresh in flight; timer ticks while busy are dropped (§4.2).
- One pending snapshot slot (replace superseded).
- Delivery to the main-actor store as `Sendable` values (use `AsyncStream` with `bufferingPolicy: .bufferingNewest(1)` rather than Combine).
- Cancellation: stop timer, drain/join worker, then restore terminal.
Tests: slow fake collector → no queue growth; cancellation joins; sequence numbers monotonic.

### WP1.7 — Store, Actions, Reducer (`AppState`, `Action`, `Reducer`)
- State: latest snapshot, selection (identity), scroll position, terminal size, status messages (bounded), refresh interval.
- Actions: key/navigation, snapshot received, resize, quit, tick.
- Reducer returns `[Effect]`; effect handlers (main-actor store) dispatch results.
- Selection by identity: if selected process disappears, select nearest neighbor deterministically (document rule).
Tests: navigation bounds, selection survives reorder, selection loss, stale snapshot rejection, no OS calls in reducer.

### WP1.8 — Terminal backend (`TerminalUI`)
- `TerminalSession`: scoped lifecycle (§7.1), restoration of exact saved `termios`, alternate screen, cursor, mouse off, style reset.
- Signal bridge: SIGINT/SIGTERM/SIGHUP/SIGWINCH via C self-pipe; coalescing safe if pipe is full.
- Decision on SIGTSTP/SIGCONT: **first release explicitly disables suspension and documents it** unless Phase 4 time allows proper restore/redraw (§7.1 permits either).
- `InputDecoder`: incremental state machine — split sequences, multiple events per read, invalid bytes, ESC timeout (bounded, e.g. 25–50 ms), UTF-8 split, bounded buffer (§7.2).
- `CellBuffer` + `DisplayWidth` + `ScreenRenderer` (diff, batched writes, short-write handling, EPIPE/disconnect).
- Text sanitizer: strip/escape C0/C1 controls, ESC, DEL; replace with visible placeholder.
Tests: decoder table-driven; fuzz with fixed seed; cell-buffer diff correctness; sanitizer hostile fixtures; pty-based lifecycle tests (open pty pair, run session, verify restoration, resize).

### WP1.9 — Process table view and layout
- Pure view function `render(state, size) -> CellBuffer`.
- Columns: PID, Name, User, CPU%, Memory (RSS), State. Priority-based column dropping under 80 columns; minimal layout / "resize" message at 20×5.
- Selection highlight; scroll keeps selection visible; footer with key hints.
- Unavailable renders `—`.
Tests: golden fixtures at 80×24 and 20×5 (add 120×40 in Phase 2).

### WP1.10 — Wiring (`RTopCLI/Main.swift`)
- Minimal parsing: `--refresh-ms` (validate ≥250, overflow-safe), `--help`, `--version` (no terminal mode). Full CLI in Phase 4 but share the option metadata table now.
- Event loop: multiplex stdin, signal pipe, timer, snapshot stream into the store; render after each reduced batch.
- Exit codes 0/1/2 (§10.3).
- Refuse to run if stdin/stdout aren't TTYs with a clear diagnostic.

### Phase 1 Gate (spec §12)
Status: implemented and automatically verified (148 tests: 50 MonitorCore, 32 MonitorDarwin, 66 TerminalUI; debug and release builds clean under warnings-as-errors; real binary exercised in a pty). Items marked *open* need a human or a decision.

- [x] Rows show PID, name, user, CPU, memory, state when available (golden tests at 80×24 / 40×8 / 20×5; live run)
- [x] Restricted metadata → partial rows, not failed refresh. On the dev machine ~⅓ of processes return EPERM for `proc_pidinfo`; they appear as partial rows (see `Documentation/Architecture.md`)
- [x] CPU unavailable until a second valid measurement (unit, fake-collector, and live tests)
- [x] Refresh interval validation; no unbounded queued refreshes (`OptionsTests`, `SamplingWorkerTests`)
- [x] q / Ctrl-C / Esc / handled SIGTERM / SIGHUP / SIGINT restore the terminal (`Scripts/pty_lifecycle_check.py`, exact `termios` compared in `Scripts/pty_idle_check.py`). *Open:* the same manual run in real Terminal.app and iTerm2
- [x] Resize incl. 20×5, 5×2, 1×1 and a resize storm do not crash (render-bounds test over widths 1–130, pty script). *Open:* manual check in a real terminal
- [x] State transitions and sampler tested with fakes
- [ ] Tag `v0.1`. *Open:* CHANGELOG is updated; no commit or tag has been made

Decisions taken in Phase 1 (all recorded in `Documentation/Architecture.md`): selection-loss rule, PID-only identity for restricted processes, Escape quits until modal/filter contexts exist, Ctrl-Z/SIGTSTP disabled, default order is PID ascending.

---

## Phase 2 — Overview, Sorting, Filtering, History (`v0.2`, ≈5–8 days)

### WP2.1 — Memory and swap
- Page size from runtime; checked arithmetic (no unsigned underflow).
- Keep raw categories separate: active, inactive, wired, free, compressor (physical occupancy), purgeable, speculative, file-backed (§6.4).
- Optional headline "Approx. used" = wired + active + compressor physical; unavailable if any component missing. Label clearly.
- No "cached" label unless a tested definition exists; show the real category name.
- Swap via `vm.swapusage`.
- Document in `Documentation/Metrics.md`.
Tests: missing categories, overflow, page-size variations (4K/16K).

### WP2.2 — Memory pressure
- Use SDK-supported notification source (dispatch memory-pressure source) on a managed queue; state `Unknown` until the first observation; store last state + timestamp/provenance (§6.5).
- Do not derive pressure from free memory.
- Validate behavior on available macOS versions; if not reliable, ship `Unknown` and document.

### WP2.3 — Load, uptime, topology
- `getloadavg`, `kern.boottime` → uptime (clamped non-negative), process counts.
- Topology: read `hw.perflevel*` once at start, cache; report counts separately; per-core rows remain **unclassified** unless a validated mapping is documented (§6.3). Include a "Topology" help note.

### WP2.4 — Sort (`ProcessSort.swift`)
- Comparators for PID, name (documented locale-independent case-insensitive rule), user, CPU, memory, state.
- Missing values last in both directions; tie-break PID → start identity.
- Keys `s` (cycle) and `r` (reverse); header indicator.
Tests: stability, missing values both directions, set-preservation property test (fixed seed).

### WP2.5 — Filter (`ProcessFilter.swift`)
- Parser: whitespace terms, AND; plain term → name or command line (if available); `pid:` exact positive; `user:` name or numeric UID; `path:` executable path; case-insensitive prefixes.
- Invalid predicate → inline error, keep last valid filter. Enter commits, Esc restores previous, empty clears. "No matching processes." empty state.
- Filter-edit buffer in state; bracketed paste (if enabled) treated purely as text.
- Only already-available command-line data is used (no eager arg reads).
Tests: grammar table, Unicode matching, malformed predicates, edit/commit/cancel reducer paths.

### WP2.6 — History and pause
- `HistoryBuffer<T>` ring buffer with timestamps and explicit unavailable samples; capacity default 60 (config later up to 3600).
- Pause: freeze presentation only; sampler continues keeping baselines; resume shows latest snapshot, no zero-fill or replay (§8.3). Space toggles when no modal consumes it.
Tests: bounds, wrap, unavailable samples, pause/resume reducer.

### WP2.7 — Overview panels
- Header: aggregate CPU bar + history sparkline, per-core bars (unclassified), load averages (labelled as load), uptime, process counts, memory categories + approx used, swap, pressure state (Unknown/Normal/…), stale indicator.
- Layout: 80×24 = overview + table + footer; 120×40 = additional columns + histories.
- ASCII fallback for bars/sparklines; wide-char handling.

### WP2.8 — Golden fixtures and reference comparison
- Golden cell-buffer tests at 80×24, 120×40, 20×5 in mono and 256-color.
- Comparison session vs Activity Monitor, `top -l 2`, `ps`, `vm_stat`, `sysctl`: record hardware, macOS, toolchain, refresh interval, CPU convention, sample alignment, process identity in `Documentation/Metrics.md`. Use controlled single-core workload (e.g., `yes > /dev/null`) and treat spec thresholds as investigation guides (§11.2).

### Phase 2 Gate (spec §12)
- [ ] CPU units, memory definitions, unknown-pressure semantics documented
- [ ] Core-class labels only with validated mapping; otherwise counts separate
- [ ] Sorting deterministic; filtering per grammar
- [ ] Identity-based selection holds across exit/filter/sort
- [ ] History bounded; pause doesn't block input or corrupt baselines
- [ ] Goldens pass at required sizes/color modes
- [ ] Reference comparisons recorded with conditions, discrepancies explained
- [ ] Tag `v0.2`

---

## Phase 3 — Safe Process Control and Details (`v0.3`, ≈4–7 days)

### WP3.1 — Lazy process details
- Effect: `loadDetails(identity, generation)` executed on the worker; result tagged with identity + generation; reducer discards mismatches (§4.2).
- Command line via SDK-supported `sysctl` (`KERN_PROCARGS2` format: argc, exec path, null-separated args); implement and unit-test the byte-format parser including truncation, max sizes, access failures. Missing → unavailable (never substitute name).
- Bounded identity-keyed cache (LRU, small cap). Command lines held in memory only, never logged.
- Detail pane (`d`): path, command line, parent, threads, virtual/resident, UID, start time; sanitized.

### WP3.2 — Process tree (`ProcessTree.swift`)
- Build from parent PIDs; PID 1 as root when present; missing-parent → synthetic "Unattached"; cycle detection; depth bound; sort within siblings.
- Tree-filter mode: matches + ancestor context rows (visually distinguished).
- Toggle `t`; selection by identity preserved across modes.
Tests: cycles, orphans, PID reuse (child's PPID points to a newer process), depth bound, 5,000-node performance.

### WP3.3 — Process controller (`MonitorDarwin/ProcessController.swift`)
- Protocol `ProcessControlling` with `send(request) -> Result<SignalSent, ControlError>`.
- Error cases: invalidTarget, protectedTarget, permissionDenied (EPERM), processExited (ESRCH), identityChanged, identityUnavailable, osFailure(errno).
- Guards: PID > 1, ≠ own PID, within valid PID range, strictly positive (never 0/negative → no group signalling); allow-listed signals only (TERM, KILL, INT, HUP, STOP, CONT).
- Re-read start identity directly before `kill`; no async work between check and call; capture `errno` immediately.
- Document the residual race in `Documentation/Permissions.md` (§9.3).

### WP3.4 — Confirmation workflow in reducer
- State machine: `idle → selecting(signal) → confirm(stage1) → [confirm(stage2) if caution] → sending → result`.
- Caution = root-owned or executable path components under `/System`, `/usr`, `/sbin` (component-wise comparison, not string prefix).
- Left/Right changes signal **and resets** any granted confirmation. `y`/`n`/Enter/Esc per §7.5; modal precedence defined in the shared key-binding table.
- Pending request captures identity, PID, name, UID, path, signal.
- If caution metadata changed at revalidation → return to confirmation.
- Result messages: "Signal sent" (not "killed"), plus ESRCH/EPERM wording without claiming SIP.
- Trigger an immediate refresh after delivery.
Tests: every transition, PID reuse mid-confirmation, selection change while modal open, double-confirm for protected, PID 1/self refusal, signal change resets confirmation.

### WP3.5 — Modal UI
- Signal modal rendering with target description, signal explanation, SIGKILL warning, stage indicators. Help overlay (`?`) generated from the binding table.

### WP3.6 — Child-process integration tests
- Test harness spawns owned children (e.g., `/bin/sleep`, a trap-ignoring shell loop), records identity, enforces timeouts, cleans up on all paths (`defer` + `tearDown`).
- Cover SIGTERM, SIGSTOP/SIGCONT (check state via sampler), explicit SIGKILL after SIGTERM ignored, ESRCH after exit, identity mismatch via forged request.
- Permission-denied covered by mocks, not real system processes.

### WP3.7 — Behavior documentation
- `Documentation/Permissions.md`: unprivileged visibility limits, EPERM cases, GUI app/service restart observations (record real observations only, no universal claims).

### Phase 3 Gate (spec §12)
- [ ] Every signal needs explicit confirmation; protected targets need second stage
- [ ] PID 1, self, invalid, unverifiable identities cannot be signalled
- [ ] Identity rechecked immediately pre-delivery; race documented
- [ ] Success = accepted, not dead
- [ ] Owned-child tests: terminate, stop/continue, explicit escalation
- [ ] Stale detail results rejected; inaccessible command line handled
- [ ] Tree handles missing parents and cycles
- [ ] Permission/service behavior documented without universal claims
- [ ] Tag `v0.3`

---

## Phase 4 — Polish, Performance, Release (`v1.0`, ≈6–10 days)

### WP4.1 — CLI and configuration
- Full option set (§10.2) from shared option metadata: `--refresh-ms`, `--sort`, `--descending`, `--theme`, `--color`, `--normalize-cpu`, `--history-samples` (1…3600), `--config`, `--no-mouse`, `--help`, `--version`.
- Distinguish "absent" from "supplied" (optional-valued parsed struct) to implement CLI > file > defaults.
- JSON `Codable` config with strict key checking (unknown keys → warning listing them); define schema doc first, then sample.
- Default file missing = normal; invalid default = visible warning + defaults; explicit file missing/invalid = exit 2.
- Paths: `~/Library/Application Support/rtop/config.json`; create directories lazily with restrictive permissions.
Tests: precedence matrix, malformed JSON, unknown keys, bounds, overflow.

### WP4.2 — Logging
- Serial file sink at `~/Library/Logs/rtop/rtop.log`, mode 0600 (dir 0700), size-rotated with retention cap; never writes to TUI; rate-limited repeated warnings; no command lines/env.

### WP4.3 — Themes and color
- Dark, light, mono; 256-color and optional truecolor; `NO_COLOR` non-empty disables color; `--color` overrides; conservative capability detection (env hints only, no name sniffing assumptions); no mandatory background queries.
- Centralize in `Theme.swift`; every golden covers mono.

### WP4.4 — Hardening
- Hostile-metadata fixtures: processes named with ESC sequences, newline, bidi controls, over-long names, invalid UTF-8; verify rendering and logging safe.
- Decoder fuzzing with fixed seeds; bracketed-paste safety; bounded buffers.
- Terminal edge cases: terminal disconnect (EIO/EPIPE), EOF on stdin, resize storms, suspend/resume (implement restore/redraw or confirm disabled and documented).
- Manual terminal recovery procedure (`reset`/`stty sane`) in README.

### WP4.5 — Optional mouse (only if time remains)
- Click-select, wheel scroll, header-click sort; strict cleanup of mouse modes on all exit paths; `--no-mouse`. Skip entirely if it jeopardizes the gate.

### WP4.6 — Performance and profiling
- Synthetic 5,000-process snapshot render benchmark (optimized build) → target <≈16 ms pure render.
- Instruments: Time Profiler (idle CPU at 1 s refresh, target <≈3% of a core), Allocations/Leaks over a 30-minute run (no growth trend after warm-up), slow-collector responsiveness (<100 ms input-to-update).
- Record distributions and environment in `Documentation/Performance.md`; revise targets with justification if missed.
- Optimize only measured hot spots (likely: string handling/width calc, full re-sort per frame, UID lookups).

### WP4.7 — Documentation
- README (Xcode + CLI build, run, key bindings, config, recovery), `Architecture.md`, `Metrics.md`, `Permissions.md`, `ReleaseChecklist.md`, man page, shell completions generated from the option metadata.
- Verify: fresh clone builds in Xcode following only the README.

### WP4.8 — Packaging and release (§13)
1. Per-architecture optimized builds (arm64; x86_64 if supported by toolchain); optional `lipo` universal before signing, verify with `lipo -info`.
2. Verify deployment target compatibility (`otool -l`/`vtool`) and linked libraries.
3. Release archive: binary, license, man page, completions, checksums.
4. Homebrew formula from real release URLs; test `brew install`/`uninstall` as users would.
5. Developer ID signing + notarization if available (credentials via CI secrets only); otherwise document source-build route. Verify on a clean Mac; never advise disabling Gatekeeper.
6. Tag `v1.0`; publish release notes with honest validation status per artifact.

### WP4.9 — Release test matrix
| Dimension | Coverage |
|---|---|
| Terminals | Terminal.app, iTerm2, one additional (e.g., Ghostty/WezTerm/Alacritty/kitty) |
| macOS | Minimum supported (14) and a newer release |
| Architecture | arm64 required; x86_64 only if hardware available, else mark unvalidated |
| Scenarios | Startup/quit, resize incl. 20×5, filter/sort/tree/details, signal workflow on owned child, color modes, `NO_COLOR`, SIGTERM/SIGHUP exit, pipe/non-TTY refusal |

### Phase 4 Gate (spec §12, §15)
- [ ] Configuration precedence and error policies tested
- [ ] Help from shared binding table; keyboard-only complete
- [ ] Sanitization and decoding withstand hostile input
- [ ] Release matrix passes in three terminals
- [ ] Instruments review: no known leaks / unbounded allocation
- [ ] Performance targets measured and met or revised with justification
- [ ] Architecture artifacts runtime-tested on advertised hardware
- [ ] Homebrew install, man page, completions, uninstall validated
- [ ] Signing/notarization status documented accurately
- [ ] Mouse (if shipped) passes selection/scroll/sort/cleanup tests
- [ ] Coverage ≥70% on core logic; every destructive-action guard tested individually

---

## Appendix A — Requirement Traceability

| Requirement | Phase / WP |
|---|---|
| FR-01 process list | P1 WP1.3–1.4, 1.9 |
| FR-02 refresh interval | P1 WP1.6, 1.10; P4 WP4.1 |
| FR-03 CPU/load/uptime/counts | P1 WP1.5; P2 WP2.3, 2.7 |
| FR-04 memory/swap/pressure | P2 WP2.1–2.2 |
| FR-05 bounded history | P2 WP2.6 |
| FR-06 sorting | P2 WP2.4 |
| FR-07 filtering | P2 WP2.5 |
| FR-08 selection by identity | P1 WP1.7; verified P2 WP2.4–2.5 |
| FR-09 pause | P2 WP2.6 |
| FR-10 details and tree | P3 WP3.1–3.2 |
| FR-11 signals with confirmation | P3 WP3.3–3.5 |
| FR-12 protected targets, revalidation | P3 WP3.3–3.4 |
| FR-13 keyboard operation (mouse optional) | P1 WP1.8; P4 WP4.5 |
| FR-14 help/config/logging/errors | P3 WP3.5; P4 WP4.1–4.2, 4.7 |
| FR-15 terminal compatibility | P0 WP0.4; P4 WP4.9 |

## Appendix B — Key Risks and Where They Are Addressed

| Risk | Addressed in |
|---|---|
| ABI/pointer lifetime errors | WP0.3, WP1.3, WP4.6 (Instruments) |
| Blocking sampler hurts input | WP1.6 |
| Swift concurrency violations | WP0.1, WP1.6, CI |
| Misleading memory figures | WP2.1, WP2.8 |
| Wrong P/E core labels | WP2.3 |
| Pressure state false claims | WP2.2 |
| PID reuse during signalling | WP3.3–3.4 |
| Terminal injection / raw-mode leakage | WP1.8, WP4.4 |
| Sensitive data in logs | WP4.2 |
| Scope creep | Phase gates; mouse and optional panels deferred |

## Appendix C — Suggested Order of First Commits

1. `Package.swift`, target skeletons, empty tests, CI workflow.
2. `SDKInteropReport.md` + C spike wrappers.
3. `Models.swift`, `Availability`, `HistoryBuffer` with tests.
4. `CPUMath` pure functions with tests.
5. `TerminalSession` + signal bridge with pty tests.
6. `InputDecoder`, `CellBuffer`, sanitizer with tests.
7. Darwin process sampler, worker, store/reducer, table view, `main` wiring → `v0.1`.

## Appendix D — Open Decisions to Resolve Early

| Decision | When | Default if undecided |
|---|---|---|
| Convert existing Xcode project to SwiftPM vs. local-package hybrid | WP0.1 | SwiftPM package, executable `rtop` |
| Suspend (Ctrl-Z) support in v1.0 | WP1.8 | Disabled and documented |
| Additional terminal for release matrix | WP4.9 | Whichever the developer has (Ghostty/WezTerm/kitty) |
| Intel (x86_64) support | WP0.2 | Build-only unless hardware available; mark unvalidated |
| Mouse support | WP4.5 | Defer past v1.0 |
| Product name availability for `rtop` (Homebrew/GitHub) | Before WP4.8 | Rename via a single constant + package name |

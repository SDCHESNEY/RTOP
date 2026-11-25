# Technical Specification: Native macOS System Monitor in Swift

**Document status:** Proposed implementation specification; no implementation or benchmark results are asserted.  
**Deliverable:** A terminal-based system monitor implemented in Swift, developed and tested through Xcode.  
**Working product name:** `rtop` (retained from the reference plan; subject to availability checks before publication).  
**Reference:** `implementation.md`.  
**Platform:** macOS only. Apple Silicon is the primary architecture; Intel support is included when supported by the selected Xcode toolchain and deployment target.  
**Interface:** Terminal user interface (TUI), not a SwiftUI desktop application.  
**Proposed baseline:** macOS 26 or later (swift-tools-version 6.2), Swift 6 language mode, and a stable Xcode release supporting both the deployment target and required architectures. Record the exact Xcode, SDK, and compiler versions at project setup. The baseline is a design choice, not a claim about minimum API requirements.

## 1. Purpose and Scope

Implement the solution described in the reference as a native Swift command-line application. The monitor shall display running processes, system and per-core CPU utilization, memory, swap, load averages, uptime, and bounded histories. It shall support sorting, filtering, process details, hierarchical process display, and explicitly confirmed process signalling.

Preserve the reference's event-driven architecture, safe process-control workflow, graceful handling of unavailable information, terminal compatibility, testing discipline, and Homebrew-oriented distribution. Replace the Rust toolchain and libraries with Swift, Foundation, Darwin interfaces, a small C interoperability boundary where necessary, and Xcode-based build and debugging workflows.

### 1.1 Goals

- Use native macOS process and system interfaces without requiring administrator privileges for normal monitoring.
- Remain responsive while collecting process information and rendering terminal updates.
- Keep operating-system calls, state transitions, and rendering independently testable.
- Preserve terminal state on normal exit, supported termination signals, and handled failures.
- Produce documented, reproducible release artifacts for supported Mac architectures.
- Make unavailable, estimated, stale, or permission-restricted metrics explicit.

### 1.2 Non-goals

- A graphical application, menu-bar application, remote-monitoring service, or privileged helper.
- Replacement of Activity Monitor or every feature of existing system monitors.
- Automatic privilege escalation or bypassing system protections.
- GPU utilization, SMC sensors, or unsupported temperature and power telemetry.
- Exact reproduction of every Activity Monitor metric where no equivalent public definition is available.
- Guaranteed terminal recovery after an uncatchable termination or corrupted runtime.

## 2. Functional Requirements

| ID | Requirement |
|---|---|
| FR-01 | Enumerate running processes and display PID, name, user, CPU percentage, resident memory, and state when available. |
| FR-02 | Refresh at a configurable interval: default 1,000 ms; reject values below 250 ms. |
| FR-03 | Display aggregate and per-core CPU utilization, load averages, uptime, and process counts. |
| FR-04 | Display physical memory, explicitly defined memory categories, swap, and an available memory-pressure state. |
| FR-05 | Maintain bounded CPU and memory histories, defaulting to 60 samples. |
| FR-06 | Sort ascending or descending by PID, name, user, CPU, memory, and state with deterministic tie-breaking. |
| FR-07 | Support case-insensitive name/command filtering and `pid:`, `user:`, and `path:` predicates. |
| FR-08 | Preserve selection by process identity across snapshots, sorting, and filtering. |
| FR-09 | Pause displayed data without blocking keyboard input, terminal resizing, or safe shutdown. |
| FR-10 | Show process details and a parent/child tree using only available information. |
| FR-11 | Offer SIGTERM, SIGKILL, SIGINT, SIGHUP, SIGSTOP, and SIGCONT only through an explicit confirmation workflow. |
| FR-12 | Refuse protected targets and revalidate target identity immediately before signalling. |
| FR-13 | Support complete keyboard operation; mouse interaction is an optional release-phase enhancement. |
| FR-14 | Provide help, validated configuration, diagnostic logging, and clear permission/error messages. |
| FR-15 | Operate in Terminal.app, iTerm2, and at least one additional terminal validated during release testing. |

## 3. Technology and Dependency Decisions

| Concern | Selected approach |
|---|---|
| Development | Xcode with a Swift package containing an executable target, reusable library targets, tests, and a C support target. |
| Language | Swift 6 language mode with strict concurrency checking; C only for ABI-sensitive system interoperation and signal handling. |
| Runtime | Foundation and Darwin system interfaces; no asynchronous runtime dependency. |
| Process collection | Native `libproc` interfaces from the reference: `proc_listpids`, `proc_pidinfo`, and `proc_pidpath`. |
| CPU and memory | Mach interfaces including `host_processor_info` and `host_statistics64`. |
| System metadata | `sysctl` / `sysctlbyname`, including available `kern.boottime`, `hw.memsize`, `vm.swapusage`, and topology values. |
| Terminal backend | A project-owned ANSI/VT-compatible renderer, POSIX terminal control, and an incremental input decoder. No curses dependency is required. |
| CLI | A project-owned parser for the bounded option set, with generated help from shared option metadata. |
| Configuration | Foundation JSON decoding into typed configuration. Use JSON instead of TOML to avoid an additional parser dependency. |
| Testing | XCTest, deterministic cell-buffer fixtures, seeded randomized tests, and child-process integration tests. |
| Profiling | Xcode Instruments: Time Profiler, Allocations, and Leaks as applicable. |
| Release | Xcode command-line build tools, architecture-specific builds, optional universal assembly, Homebrew formula, optional Developer ID signing and notarization. |

The ANSI backend is an explicit engineering responsibility: escape parsing, display widths, resize handling, screen diffing, and terminal restoration require tests. Keep its API replaceable if a separately evaluated Swift TUI dependency is adopted later. Do not assume a terminal's capabilities from its application name alone.

### 3.1 Xcode and Package Setup

1. Create a Swift package with an executable product named `rtop` and the target structure below.
2. Open `Package.swift` in Xcode. Use the package's generated executable scheme, or a shared scheme if a workspace is introduced.
3. Set the deployment target and language mode explicitly; keep supported architectures consistent across all targets.
4. Add a C target with a public header and implementation for the required Darwin interoperation. Do not use an application bridging header for package targets.
5. During the setup spike, verify SDK header availability, required link settings, imported types, structure sizes, and return-value contracts for every native call. Treat the selected SDK headers as authoritative.
6. Keep App Sandbox disabled: this is a developer-distributed terminal executable, not a sandboxed desktop app. Do not request unnecessary entitlements.
7. Use Xcode for compilation, unit tests, breakpoints, and Instruments. Run the actual TUI from a real terminal; Xcode's debug console is not an acceptance-test terminal.
8. For interactive debugging, launch the executable in a terminal and attach Xcode's debugger to that process.

Do not hard-code hosted CI runner labels or presume their architecture. Select supported macOS runners at implementation time and record their actual architectures.

## 4. Architecture

### 4.1 Unidirectional Event Flow

The application has four logical stages:

1. **Input and lifecycle events:** decoded keys, mouse events where enabled, terminal dimensions, shutdown requests, and timer notifications.
2. **Sampling:** a serial background worker collects native data and publishes immutable snapshots.
3. **State reduction:** a main-actor store translates events into actions and applies all application-state mutations.
4. **Rendering:** a pure renderer produces a terminal cell buffer from state and dimensions; a separate output adapter writes the frame difference.

Collection never accesses terminal output or mutates application state. Rendering never performs process inspection, reads configuration, or sends signals. Process-control side effects return explicit result events to the store.

### 4.2 Concurrency Model

- Keep application state and terminal output main-actor isolated.
- Run potentially blocking process enumeration and detail lookup on a dedicated serial worker, not the main actor.
- Use immutable, `Sendable` value models for snapshots and cross-isolation results.
- Serialize collector calls so CPU baselines and native buffers cannot be accessed concurrently.
- Allow at most one refresh in flight. If the collector is behind, skip redundant timer requests instead of creating an unbounded queue.
- Keep at most one pending snapshot awaiting presentation. Replace superseded pending samples.
- Tag asynchronously requested detail results with process identity and request generation; discard results for a previously selected process.
- Use a monotonic clock for sample intervals and CPU deltas; wall-clock time is for display and process start dates only.
- Cancellation must stop new work, dispose of event sources, join or safely drain the sampler, and restore the terminal before returning control to the shell.

No `@unchecked Sendable` conformance is permitted without a documented ownership invariant and a specific review. Do not wrap blocking system calls in an actor and assume they cannot affect the cooperative executor.

### 4.3 Proposed Source Layout

All names below are proposed project-owned names, not claims about existing framework APIs.

```text
rtop/
├── Package.swift
├── Package.resolved                 # when dependencies are introduced
├── README.md
├── technicalspecification.md
├── CHANGELOG.md
├── Sources/
│   ├── RTopCLI/
│   │   ├── Main.swift
│   │   └── CommandLineOptions.swift
│   ├── MonitorCore/
│   │   ├── Models.swift
│   │   ├── AppState.swift
│   │   ├── Action.swift
│   │   ├── Reducer.swift
│   │   ├── ProcessSort.swift
│   │   ├── ProcessFilter.swift
│   │   ├── ProcessTree.swift
│   │   ├── HistoryBuffer.swift
│   │   └── Configuration.swift
│   ├── MonitorDarwin/
│   │   ├── DarwinCollector.swift
│   │   ├── ProcessSampler.swift
│   │   ├── CPUSampler.swift
│   │   ├── MemorySampler.swift
│   │   ├── SystemMetadata.swift
│   │   ├── ProcessController.swift
│   │   └── NativeError.swift
│   ├── TerminalUI/
│   │   ├── TerminalSession.swift
│   │   ├── InputDecoder.swift
│   │   ├── CellBuffer.swift
│   │   ├── ScreenRenderer.swift
│   │   ├── DisplayWidth.swift
│   │   ├── Theme.swift
│   │   └── KeyBindings.swift
│   └── DarwinSupport/
│       ├── include/DarwinSupport.h
│       └── DarwinSupport.c
├── Tests/
│   ├── MonitorCoreTests/
│   ├── MonitorDarwinTests/
│   └── TerminalUITests/
└── Documentation/
    ├── Architecture.md
    ├── Metrics.md
    ├── Permissions.md
    └── ReleaseChecklist.md
```

### 4.4 Interoperability Boundary

The C support target shall own ABI-sensitive interactions rather than scattering pointer rebinding across Swift code.

- Verify native structure layouts using SDK types; never reproduce opaque layouts from memory.
- Validate native return lengths before consuming structures.
- Distinguish byte counts from element counts.
- Handle zero-length results, allocation failures, process exit during inspection, and changing enumeration sizes.
- Pair every native allocation, Mach-returned buffer, and acquired resource with its documented release operation.
- Follow each API's actual ownership contract; not every Mach function transfers the same ownership.
- Copy native results into owned Swift values before native storage is released.
- Capture `errno` immediately for APIs that use it. Mach status codes must be interpreted separately.
- Bound string decoding and replace invalid byte sequences without crashing.
- Unit-test calculations independently from FFI; integration-test the boundary against real processes.

Any helper functions or exported records introduced in this target must be declared in its checked-in header before use from Swift. This document does not prescribe unverified Swift import signatures for Darwin APIs.

## 5. Domain Model and State

### 5.1 Snapshot

| Proposed field | Meaning |
|---|---|
| `sequence` | Monotonically increasing sample number. |
| `sampleTime` | Monotonic completion timestamp. |
| `sampleDuration` | Collection duration and diagnostic freshness information. |
| `cpu` | Aggregate busy utilization and per-logical-CPU readings. |
| `memory` | Raw VM categories, physical total, display approximation, pressure state and provenance. |
| `swap` | Optional used and total bytes. |
| `loadAverage` | Optional one-, five-, and fifteen-minute values. |
| `uptime` | Optional duration since boot. |
| `processes` | Process summaries, including partial records. |
| `warnings` | Structured, bounded collection warnings, not one unbounded message per inaccessible process. |

### 5.2 Process Identity and Summary

Use a composite identity consisting of PID and the available high-resolution start timestamp. Preserve the native timestamp precision; do not reduce it to whole seconds. PID alone is insufficient for selection, CPU accounting, or process control.

A process summary contains optional parent PID, name, executable path, command line, numeric UID, resolved user name, CPU percentage, resident bytes, virtual bytes, thread count, and status. The numeric UID remains useful when user-name lookup fails.

An enumerated process with inaccessible metadata remains visible with unavailable fields. An exited process may disappear before the next sample completes; do not fail the whole refresh. When start identity is unavailable, display a partial row but disable identity-sensitive control actions.

Treat `root-owned` and `system-path` as caution flags, not proof of operating-system protection or permission to signal.

### 5.3 Availability and Error Semantics

Represent unavailable metrics explicitly rather than coercing them to zero. For important fields, preserve a reason: permission denied, process exited, unsupported, not yet sampled, malformed result, or collection failed.

A zero value means measured zero. The UI renders unavailable data as `—`, optionally with a detail explanation. A stale snapshot remains visible with a stale indicator and timestamp if a subsequent sample fails.

### 5.4 Application State

The state stores the latest displayed snapshot, selected process identity, sort descriptor, parsed filter, filter-edit buffer, scroll position, tree/detail mode, active modal, pause state, theme, terminal dimensions, histories, and bounded status messages.

The reducer is the only mutation point. It returns side-effect requests such as collecting details or sending a confirmed signal. Effect handlers execute those requests and dispatch result actions. Tests shall verify that rendering and reducers do not invoke the operating system.

## 6. Native Collection Specification

### 6.1 Process Enumeration and Details

Use `proc_listpids` with the SDK-defined enumeration options. Size the buffer defensively, retry a bounded number of times if it fills, and tolerate membership changes. Never treat enumeration as an atomic operating-system snapshot.

Use supported `proc_pidinfo` queries for BSD information and task information; validate every returned length. Use `proc_pidpath` for an optional executable path. Retrieve expensive command-line and extended detail information lazily for the selected process, with a bounded identity-keyed cache.

If command arguments are obtained from an SDK-supported `sysctl` facility, implement and test the exact returned byte format, including argument counts, null separators, maximum sizes, and access failures. Do not substitute executable name for a supposedly complete command line. A missing command line remains unavailable.

Resolve user names outside the render path and cache by numeric UID with a bounded lifetime. Avoid per-row repeated lookups and unsafe use of shared native buffers.

Map native statuses conservatively. Do not infer a precise process state from CPU usage or a failed task query. Unknown states render as unknown.

### 6.2 CPU Utilization

Maintain cumulative CPU counters for each process identity and logical CPU. Compute process CPU percentage from the delta of task user-plus-system CPU time divided by monotonic elapsed sample time, multiplied by 100. Convert source units explicitly and document the conversion in `Metrics.md`.

The default process scale is one fully occupied core = 100%; a multithreaded process may exceed 100%. Optional normalized mode divides by the usable logical-CPU count. Label the selected convention clearly.

For host CPU, derive busy fractions from deltas of the available Mach tick categories. Aggregate utilization uses the sum of busy deltas divided by the sum of total deltas, not an unweighted mean of missing or invalid cores.

- The first observation is unavailable, not zero.
- New processes start their own baseline.
- A changed start timestamp invalidates the previous PID baseline.
- Counter reset, wraparound, nonpositive elapsed time, and CPU-count changes invalidate the affected interval.
- Do not compare non-aligned sampling windows as though they were exact equivalents.

### 6.3 Apple Silicon Topology

Read available `hw.perflevel*` metadata using the selected SDK and observed system support. Treat absent keys as expected.

Performance-level core counts alone do not prove how the per-core tick array maps to performance and efficiency cores. Do not assume that logical CPU indexes are contiguous by class or that a fixed performance-level index always implies a particular core type.

Only label individual cores after a supported, validated mapping exists. Otherwise display unclassified per-core usage plus separately reported topology counts, with an explanation in help. Intel and unknown hardware fall back to a single unclassified group. A guessed topology is not an acceptable substitute.

### 6.4 Memory and Swap

Read physical memory from `hw.memsize` and VM categories from `host_statistics64` where available. Obtain the runtime page size; never assume 4 KiB or 16 KiB. Convert pages to bytes with checked arithmetic.

Keep raw active, inactive, wired, free, compressor, purgeable, speculative, and file-backed categories separate where the SDK supplies them. These are not necessarily disjoint, and they must not be blindly summed into a stacked bar.

For continuity with the reference, an optional headline estimate may use wired bytes + active bytes + compressor physical bytes, but it must be labelled **Approx. used** and documented as a project definition, not Activity Monitor's exact Memory Used. Use compressor physical occupancy rather than the logical size of pages represented by compression. If required components are missing, the estimate is unavailable.

Show cached memory only when a tested definition is established; expose the underlying file-backed or reclaimable category by its actual name instead of inventing an equivalent. Display raw categories independently if a trustworthy partition is unavailable.

Read swap information through `vm.swapusage` when available. Never use a subtraction or VM-category formula that can underflow to a very large unsigned value.

### 6.5 Memory Pressure

Use an SDK-supported memory-pressure notification mechanism for reported transitions when available. Verify behavior on supported macOS versions before shipping.

Notification events do not guarantee an immediate queryable current state, and event coalescing is possible. Until a reliable initial state is established, show **Unknown**. Preserve the last observed state with provenance; a lack of events does not prove pressure is normal.

Do not derive Normal/Warning/Critical solely from free-memory percentage. Do not claim Activity Monitor equivalence without observations and an explained metric relationship. A release may expose Unknown rather than fabricate a state.

### 6.6 Load, Uptime, and Collection Quality

Use native load-average facilities and `kern.boottime` for system metadata. Label load averages as load, not CPU percentage. Avoid negative uptime after wall-clock adjustments and use monotonic measurements for elapsed sampling time.

A refresh report records duration, process-count observations, unavailable-field counts, and systemic failures. Cache static or slow-changing metadata; do not perform topology and physical-memory lookups for every process or render frame.

## 7. Terminal Interface

### 7.1 Terminal Lifecycle

- Verify that interactive standard input and output are terminals before changing settings. Otherwise exit with a clear diagnostic; a noninteractive export mode is not part of this scope.
- Save the original terminal settings and restore the exact saved state, not an assumed default.
- Enter the alternate screen, hide the cursor, and configure raw input deliberately.
- Handle Ctrl-C as an application exit action in raw mode. Support SIGINT, SIGTERM, SIGHUP, and resize notifications through an audited event bridge.
- Native signal handlers may only perform async-signal-safe operations, such as writing a notification to a nonblocking self-pipe. They must not allocate, log, render, or call arbitrary Swift code.
- Keep pipe-full behavior safe: flags or coalesced notifications must still permit shutdown and resize processing.
- On all handled exit paths, disable any enabled mouse mode, reset styling, show the cursor, leave the alternate screen, and restore terminal settings.
- A scoped session object provides cleanup on normal unwinding, but `deinit` is not a guarantee after fatal runtime failure, SIGKILL, or power loss. Document a manual terminal-reset recovery procedure.
- Support suspend/resume by restoring settings before suspension and reinitializing/redrawing after continuation, or explicitly disable and document suspension for the first release. Never suspend while knowingly leaving the shell terminal in raw mode.

### 7.2 Input Decoding

Decode UTF-8 and escape sequences incrementally. Handle sequences split across reads, multiple events per read, invalid bytes, and a bounded timeout distinguishing Escape from a longer sequence. Bound parser storage and ignore unsupported escape sequences safely.

Prefer plain keys and standard navigation sequences. No required action may depend on Option/Alt configuration. If bracketed paste is supported, pasted filter text must never be interpreted as process-control commands.

### 7.3 Screen Rendering

Render into a cell buffer containing grapheme content, display width, and style. Diff against the last emitted frame; batch output writes and handle short writes and terminal disconnection.

Sanitize all operating-system-derived text before placing it on screen. Process names, paths, command arguments, user names, and error text may contain control characters or escape bytes; none may become executable terminal control sequences.

Account for combining marks and double-width characters. Terminal width behavior is not identical across emulators; provide an ASCII fallback and document ambiguous-width behavior. Do not truncate inside a UTF-8 sequence or leave a half-rendered wide character.

At 80×24 show the overview, process table, and footer. At 120×40 show additional columns and histories. Below 80 columns drop low-priority columns; at 20×5 show a minimal usable layout or resize message without crashing. Scrolling must keep the selected row visible.

### 7.4 Color and Themes

Provide dark, light, monochrome, 256-color, and optional true-color paths. Respect a nonempty `NO_COLOR` environment value by disabling color. Use capability hints conservatively and allow explicit overrides.

Do not assume automatic macOS appearance detection reflects a terminal profile. Default to a documented theme, expose `--theme`, and only use terminal background queries if they are bounded, optional, and safely parsed.

### 7.5 Default Key Bindings

| Key | Action |
|---|---|
| `q`, Ctrl-C | Quit. |
| Escape | Dismiss modal, cancel filter editing, close detail, or quit if no context is active. |
| Up/Down, `j`/`k` | Move selection; `k` is navigation and never termination. |
| Page Up/Page Down | Move by a visible page. |
| Home/End | Select first/last visible process. |
| `s` | Cycle sort field. |
| `r` | Reverse sort order. |
| `/` | Edit live filter. |
| Enter | Commit filter, open selected process details, or confirm the active confirmation modal. |
| Space | Pause/resume presentation when no modal consumes it. |
| `t` | Toggle process tree. |
| `d` | Toggle process details. |
| `x` | Open signal confirmation, defaulting to SIGTERM. |
| Left/Right in signal modal | Change selected signal and reset any previously granted confirmation. |
| `y` / `n` in signal modal | Confirm / cancel when the current confirmation stage permits it. |
| `?` | Show help. |

This intentionally changes the reference's kill key because `k` is reserved for conventional upward navigation. All bindings and help content must come from one metadata table, with explicit context precedence.

## 8. Sorting, Filtering, History, and Tree Behavior

### 8.1 Sorting

Use a deterministic comparator for each field. Tie-break by PID and then start identity. Missing values sort last in both directions. Name comparison uses a documented case-insensitive rule independent of a changing UI locale. Sorting must preserve the set of process identities.

### 8.2 Filtering

Whitespace-separated terms are combined with AND. Unprefixed terms match name or available command line. `pid:` requires an exact valid positive PID; `user:` matches the user name or exact numeric UID; `path:` matches an available executable path. Prefixes are case-insensitive. Version 1 does not require quoting or regular expressions.

Invalid predicates show an inline error and retain the last valid filter. Enter commits the current valid filter; Escape restores the filter that was active before editing. An explicit clear action or deleting all text clears the filter. An empty result displays “No matching processes.”

Only available command-line data participates; do not eagerly read every process's full arguments merely to satisfy filtering without a measured performance and privacy review.

### 8.3 History and Pause

Use fixed-capacity ring buffers. Store timestamps and unavailable samples explicitly. A display pause retains the current screen, selection context, and visible history while the sampler may continue maintaining CPU baselines. On resume, display the latest complete snapshot; do not append artificial zero samples or replay an unbounded backlog.

### 8.4 Process Tree

Build parent-child relationships from the snapshot. Treat the hierarchy as an imperfect observation: parents can exit, identifiers can be reused, and enumeration is not atomic. PID 1 is the expected main root when present; missing-parent processes go under a synthetic “Unattached” group rather than inventing a parent relationship.

Detect cycles, bound traversal depth, and apply sorting within sibling groups. In tree-filter mode include matching processes and their ancestor context, with context-only rows visually distinguished.

## 9. Safe Process Control

### 9.1 Confirmation Workflow

1. Capture selected identity, PID, name, numeric UID, path, and chosen signal in a pending request.
2. Show a modal identifying the target and explaining the selected signal. SIGTERM is the default. SIGKILL is explicitly destructive and is never an automatic escalation.
3. Require a second, distinct confirmation stage for root-owned targets or paths beneath `/System`, `/usr`, or `/sbin`. Check actual path components, not a loose string prefix.
4. Immediately before delivery, re-read the target's start identity and compare it with the pending request.
5. Cancel if the process exited, identity changed, or identity cannot be verified. If caution-relevant metadata changed, require renewed confirmation.
6. Invoke `kill` only with a verified strictly positive PID and an allow-listed signal.
7. Capture the return value and native error immediately; post a result to the UI and refresh promptly.

Refuse PID 1, the monitor's own PID, zero, negative identifiers, and any identifier outside the native PID range. Never accidentally address a process group.

### 9.2 Error Model

Proposed domain cases include invalid target, protected target, permission denied, process exited, identity changed, identity unavailable, and operating-system failure with preserved native error information.

`ESRCH` means the target no longer exists at delivery; `EPERM` means permission was denied. Do not label an ordinary permission denial as proven SIP enforcement. Display ownership hints only when supported by the observed target metadata. Do not suggest disabling system protections.

A successful `kill` return means the kernel accepted signal delivery; it does not mean the process exited. Show “Signal sent” and observe later samples. A process may handle or ignore SIGTERM, and a managed service may restart with a new identity.

### 9.3 Residual PID Race

A start-time check narrows the PID-reuse window but does not make a later PID-based `kill` atomic with that check. A process can exit and its PID can be reused between validation and delivery. Document this residual race; do not claim guaranteed identity-bound signalling with these interfaces. Keep the validation-to-delivery interval minimal and avoid intervening asynchronous work.

## 10. Configuration, CLI, Logging, and Privacy

### 10.1 File Locations

- Configuration: `~/Library/Application Support/rtop/config.json`.
- Logs: `~/Library/Logs/rtop/rtop.log`.
- Optional explicit configuration path through `--config`.

These are native macOS locations. Create directories only when needed and use restrictive permissions for potentially sensitive diagnostics.

### 10.2 Proposed CLI Contract

| Option | Values / behavior |
|---|---|
| `--refresh-ms` | Integer, default 1000, minimum 250; reject malformed or overflowing input. |
| `--sort` | `pid`, `name`, `user`, `cpu`, `memory`, or `status`. |
| `--descending` | Request descending initial sort. |
| `--theme` | `dark`, `light`, or `mono`. |
| `--color` | `auto`, `never`, `256`, or `truecolor`; `NO_COLOR` still disables color. |
| `--normalize-cpu` | Normalize process CPU percentages to total logical capacity. |
| `--history-samples` | Positive bounded integer; default 60, proposed maximum 3600. |
| `--config` | Explicit configuration file path. |
| `--no-mouse` | Disable mouse events if mouse support is implemented. |
| `--help` | Print usage without entering terminal mode. |
| `--version` | Print the built version without entering terminal mode. |

Use the native collector only; there is no second implementation exposed through a collector-selection flag.

### 10.3 Configuration Semantics

Precedence is CLI > configuration file > built-in defaults. Distinguish an absent CLI option from an explicitly supplied value.

A missing default configuration file is normal. An invalid default file produces a visible warning and uses validated defaults plus CLI overrides. A missing or invalid explicitly requested file is a startup error. Unknown keys produce an actionable warning to catch misspellings. Define and test exact JSON keys in the implementation schema before documenting sample configuration.

Exit status 0 means successful normal exit, 2 means invalid CLI/configuration input, and 1 means a startup or runtime failure. These are proposed application conventions.

### 10.4 Logging and Sensitive Data

Use a serial logging sink with bounded size rotation and a documented retention cap. Do not write logs to the active TUI output stream. Rate-limit repeated permission and sampling warnings.

Command arguments may contain secrets. Do not persist command lines, environment variables, or full process listings by default. Display requested details locally, sanitize control characters, and keep caches bounded. Do not collect network telemetry from the user's machine or upload diagnostics automatically.

## 11. Testing and Validation

### 11.1 Automated Tests

| Layer | Required tests |
|---|---|
| Domain logic | Stable sorting, missing values, filter parsing, malformed predicates, Unicode matching, history bounds, tree cycles and missing parents. |
| Reducer | Navigation, PID reuse, selection loss, modal precedence, filter cancel/commit, pause/resume, and stale result rejection. |
| CPU/memory arithmetic | First sample, zero elapsed time, counter reset, unit conversion, overflow prevention, changing CPU count, and missing categories. |
| Input decoder | Partial escape sequences, Escape timeout, split UTF-8, paste handling where supported, invalid bytes, and bounded storage. |
| Renderer | Golden cell buffers at 80×24, 120×40, and 20×5; monochrome and color modes; wide characters; hostile control sequences. |
| Native collector | Buffer ownership, partial enumeration, inaccessible fields, process exit during sampling, and repeated refresh resource stability. |
| Process controller | Protected PIDs, invalid identifiers, identity mismatch, unverified identity, permission mapping, and every confirmation transition. |
| Integration | Spawn owned test children; verify SIGTERM, SIGSTOP/SIGCONT, and explicitly confirmed SIGKILL behavior. |
| Terminal lifecycle | Pseudo-terminal tests for saved-setting restoration, EOF, resize, handled shutdown, partial output, and suspend/resume if supported. |
| Configuration | Precedence, malformed JSON, unknown keys, default-file fallback, explicit-file failure, and numeric bounds. |

Use dependency-injected collectors, clocks, process controllers, terminal sinks, and native boundary adapters. Run fixed-seed randomized invariant tests where useful; no property-testing package is required initially.

Integration tests may signal only child processes created and owned by the test suite. Record identities, implement timeouts, and clean up children on every exit path. Never test by terminating arbitrary system processes. Permission-denied behavior can be deterministically mocked; optional manual checks must not endanger system services.

### 11.2 Reference Comparisons

Compare against Activity Monitor, `top -l 2`, `ps`, `vm_stat`, and relevant `sysctl` output. Record hardware, macOS version, toolchain, refresh interval, CPU convention, sample-window alignment, and process identity.

Proposed investigation thresholds, not claims of established equivalence:

- Controlled single-core process workload: approximately ±5 percentage points of an aligned reference CPU reading after warm-up.
- Host CPU: approximately ±5 percentage points across comparable windows.
- Resident process memory: approximately ±5% for a stable process, only when the compared reference uses the same resident-memory definition.
- Physical memory total: exact agreement when sources report the same byte quantity.
- Wired/compressor categories: explain source and temporal differences; do not apply an Activity Monitor equivalence test to the approximate headline used-memory metric.
- Pressure and core-class labels: accept only observed, supported data; Unknown/unclassified is valid when evidence is unavailable.

Thresholds shall be refined using measurements and documented before becoming release gates.

### 11.3 Performance Targets

These are proposed targets requiring measurements, not benchmark results:

- Below approximately 3% of one core for the monitor at 1-second refresh on a documented Apple Silicon test Mac under a representative process load.
- Pure cell-buffer rendering below approximately 16 ms for a synthetic 5,000-process snapshot at fixed terminal dimensions in an optimized build. Measure actual terminal output separately.
- Bounded queues and histories; no sustained memory-growth trend during a 30-minute run after warm-up.
- Responsive navigation during deliberately slowed collection; target input-to-visible-update below 100 ms under the documented test conditions.

Record sample distributions and environment details rather than a single best-case measurement. Large real-process stress tests are optional and must be bounded and cleaned up; synthetic snapshots are the mandatory high-count test path.

### 11.4 CI

Run builds and XCTest on available Apple Silicon and Intel macOS runners where the selected toolchain supports them. At least one job shall exercise Swift 6 concurrency checks and treat project warnings as failures. Run both debug tests and release compilation.

Archive test results and coverage. Target at least 70% coverage for pure core logic, with explicit tests for every destructive-action guard regardless of aggregate coverage. If hardware or runner availability prevents an architecture test, mark that artifact unvalidated rather than implying coverage.

Test the minimum supported macOS version and a newer supported version on actual or suitable virtualized Macs before release. Compilation against a deployment target alone is not runtime verification.

## 12. Phased Implementation and Acceptance Criteria

### Phase 0 — Xcode Setup and Native API Spike

**Deliverables:** Package targets, executable scheme, baseline tests, CI, and an SDK interoperability report.

- [ ] Xcode opens the package, builds the executable, and runs XCTest.
- [ ] Exact toolchain, SDK, deployment target, and architecture policy are recorded.
- [ ] Minimal collection reads process identifiers, physical memory, and host CPU counters without leaked resources.
- [ ] Required native headers, ownership contracts, structure sizes, and link settings are validated.
- [ ] The terminal proof of concept enters and restores terminal mode in Terminal.app and iTerm2.
- [ ] No privileged helper, sandbox entitlement workaround, or third-party runtime is required.

### Phase 1 — Read-Only Foundation (`v0.1`)

**Deliverables:** Native collector, event pipeline, navigation, and process table.

- [ ] Rows display available PID, name, user, CPU, memory, and state information.
- [ ] Restricted metadata produces partial rows, not a failed full refresh.
- [ ] CPU warm-up is unavailable until a second valid measurement exists.
- [ ] Refresh intervals validate correctly; redundant refreshes cannot queue indefinitely.
- [ ] Quit, Ctrl-C, handled termination, and recoverable errors restore saved terminal state.
- [ ] Real-terminal resize tests, including 20×5, do not crash.
- [ ] State transitions and sampler behavior are tested with fakes.

### Phase 2 — Overview, Sorting, Filtering, and History (`v0.2`)

**Deliverables:** CPU/memory panels, topology metadata, histories, sorting, filtering, and pause.

- [ ] CPU units, memory category definitions, and unknown-pressure semantics are documented.
- [ ] Per-core class labels appear only with a validated mapping; otherwise topology counts are separate.
- [ ] Sorting is deterministic and filtering follows the specified grammar.
- [ ] Selection uses process identity and behaves predictably after exit or filtering.
- [ ] History storage is bounded; pause does not block input or corrupt CPU baselines.
- [ ] Golden rendering fixtures pass at the required sizes and color modes.
- [ ] Reference comparisons include measurement conditions and explain discrepancies.

### Phase 3 — Safe Process Control and Details (`v0.3`)

**Deliverables:** Signal workflow, details, tree view, and child-process integration tests.

- [ ] Every signal requires explicit confirmation; dangerous-target confirmation has a separate stage.
- [ ] PID 1, self, invalid PIDs, and unverifiable identities cannot be signalled.
- [ ] Start identity is rechecked immediately before delivery; the residual race is documented.
- [ ] Success means signal accepted, not assumed process death.
- [ ] Owned child tests cover termination, stopping/continuing, and explicit escalation.
- [ ] Lazy details reject stale results and handle inaccessible command lines.
- [ ] Tree construction tolerates missing parents and cycles.
- [ ] Permissions, GUI-app behavior, and observed service restart behavior are documented without claiming universal outcomes.

### Phase 4 — Polish, Performance, and Release (`v1.0`)

**Deliverables:** Validated configuration, help, themes, diagnostics, performance report, and distributable artifacts.

- [ ] Configuration precedence and error policies have tests.
- [ ] Help covers the shared binding table; keyboard-only operation is complete.
- [ ] Text sanitization and input decoding withstand malformed and hostile process metadata.
- [ ] Terminal.app, iTerm2, and one additional terminal pass the release matrix.
- [ ] Instruments review finds no known native-buffer leak or unbounded allocation path.
- [ ] Performance targets are measured and met or explicitly revised with justification.
- [ ] Architecture artifacts are runtime-tested on the hardware advertised as supported.
- [ ] Homebrew installation, manual page, completions, and uninstall behavior are validated.
- [ ] Signing/notarization status and installation implications are documented accurately.
- [ ] Optional mouse support passes selection, scrolling, sorting, and cleanup tests if shipped.

Optional scope after these gates: at most two reliable unprivileged panels, such as disk capacity, network throughput, or system thermal state. Each requires a separately verified native API, metric definition, and test plan. Do not delay the core release for optional telemetry.

## 13. Packaging and Release

1. Produce optimized builds separately for supported architectures using the selected Xcode toolchain.
2. Prefer separate artifacts unless a universal binary is needed. If combining compatible slices with `lipo`, combine before final signing and verify the resulting architectures.
3. Verify deployment-target compatibility and linked dependencies; do not assume that a build succeeding on the developer Mac proves compatibility with older supported systems.
4. Create release archives with the executable, license, manual page, checksums, and shell completions generated from the shared CLI metadata.
5. Create a Homebrew formula from real repository and release URLs once those exist. No tap name, checksum, or download address is prescribed before publication.
6. If Developer ID signing and notarization are used, follow the current Apple workflow for the selected artifact format and verify the final distributed artifact on a clean Mac. The correct Gatekeeper assessment may depend on packaging; signature verification alone is not proof that installation succeeds.
7. If signing/notarization is unavailable, state that plainly and document a source-build route. Do not recommend disabling Gatekeeper globally or portray quarantine removal as the preferred installation procedure.
8. Keep CI signing credentials out of the repository and logs, and never make signing a prerequisite for local development tests.

Homebrew installation must be tested as the actual user-facing installation path. A local source build does not validate a downloaded bottle or release archive.

## 14. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| ABI or pointer-lifetime mistakes | Small audited C boundary, SDK-defined records, checked lengths, ownership tests, and Instruments. |
| Blocking sampling degrades interaction | Dedicated serial worker, bounded requests, and main-actor-only UI work. |
| Swift concurrency violations | Immutable Sendable snapshots, clear isolation boundaries, compiler checks, and stale-result tests. |
| Memory figures appear equivalent but are not | Preserve raw metrics, label estimates, document definitions, and compare like-for-like values. |
| Incorrect performance/efficiency core labels | Require supported mapping; retain unclassified per-core fallback. |
| Memory-pressure events do not establish current state | Preserve provenance and Unknown initial state; never infer from free bytes alone. |
| PID reuse during control | High-resolution identity checks, minimal validation-to-delivery interval, and disclosure of the remaining race. |
| Terminal injection or malformed input | Sanitize process-derived strings, incremental bounded parsing, and hostile-fixture tests. |
| Terminal left in raw mode | Exact saved-state restoration, signal bridge, pseudo-terminal tests, and documented unrecoverable cases. |
| Sensitive information in diagnostics | Minimal logging, bounded retention, restrictive permissions, and no default command-line logging. |
| Unsupported release architecture or OS | Explicit runtime test matrix and honest validation status for each artifact. |
| Scope expansion | Complete phase gates before optional panels or mouse refinements. |

## 15. Documentation and Definition of Done

The repository shall include installation/build instructions for Xcode and the command-line toolchain, CLI reference, bindings, architecture description, metric definitions, permission behavior, terminal recovery, configuration semantics, release validation, and known limitations.

Project completion requires:

- [ ] All mandatory functional requirements and phase gates pass.
- [ ] Proposed API wrappers and domain symbols have actual checked-in declarations and tests.
- [ ] No unsupported exactness claims for Activity Monitor parity, topology mapping, pressure state, or signal-target guarantees.
- [ ] Automated tests cover pure logic, rendering, native resource handling, and all destructive-action guards.
- [ ] CI and manual testing cover the declared macOS/architecture matrix, with omissions explicitly identified.
- [ ] Resource and performance measurements are recorded rather than assumed.
- [ ] A fresh clone builds through Xcode following only the README.
- [ ] A clean-machine installation works through the documented distribution path.
- [ ] Version tags `v0.1`, `v0.2`, `v0.3`, and `v1.0` correspond to usable phase deliverables.

## 16. Estimated Implementation Sequence

These are planning estimates for one developer, not commitments or measured effort.

| Phase | Focus | Estimated effort |
|---|---|---|
| 0 | Package setup, Xcode workflow, native API and terminal spikes | 1–2 working days |
| 1 | Collection, concurrency, and read-only process table | 5–7 working days |
| 2 | Metric definitions, overview, sorting/filtering, histories | 5–8 working days |
| 3 | Process control, detail/tree, safety tests | 4–7 working days |
| 4 | Terminal hardening, profiling, packaging, documentation | 6–10 working days |

Re-estimate after Phase 0. A project-owned terminal backend and native collection from the first phase represent more implementation work than adopting the reference's ready-made rendering and collection libraries.

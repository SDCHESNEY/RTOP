# Metrics: units, conventions, and what is not claimed

Covers process CPU, host CPU, resident memory, state, load (Phase 1), and memory categories, swap, pressure, uptime, topology, sorting, filtering, history and pause (Phase 2).

## Process CPU %

- Source: `proc_pidinfo(PROC_PIDTASKINFO)` cumulative user + system time, converted from mach absolute time to nanoseconds in the C layer (128-bit intermediate, no overflow).
- Value: `Δ(cpu ns) / Δ(monotonic ns) × 100` between two successive readings of the **same process identity** (PID + start time). 100 means one logical CPU fully busy ("Irix" convention), so a multithreaded process can exceed 100. With `--normalize-cpu` (or `normalizeCpu` in the config file) the displayed value is divided by the logical-CPU count (`hw.perflevel*` total, else the number of per-core readings) and the column is headed `NCPU%`; if the count is unknown the value is unavailable (`—`), never unscaled. Sorting is unaffected because the scaling is monotonic.
- Each process is timestamped immediately after its own task-info read, so slow enumeration does not skew individual rows.
- The first reading of a process is `unavailable(notYetSampled)`. Also unavailable (and the new reading becomes the baseline): a counter that went backwards, nonpositive elapsed time, or a changed start time (PID reuse). A process whose start time could not be read is never baselined (`collectionFailed`).
- Elapsed time uses the monotonic uptime clock, never wall-clock time.
- Not claimed: parity with Activity Monitor or `top`. Phase 2 records a comparison with conditions.

## Host CPU %

- Source: `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` per-logical-CPU tick counters (32-bit, wrapping).
- Aggregate = Σ busy deltas ÷ Σ total deltas across all CPUs (**not** a mean of per-core percentages). Busy = user + system + nice. Per-core values use the same arithmetic per CPU.
- Wraparound is handled with wrapping subtraction. A changed CPU count or zero elapsed ticks makes the interval unavailable.
- Per-core values are not labelled performance/efficiency (no validated index mapping).

## Memory column

Resident size from task info (`pti_resident_size`). It is per-process resident memory only, not "memory used" in the Activity Monitor sense. Shown in binary units (K/M/G = 1024-based).

## State column

Conservative mapping of the BSD process status: idle, running, sleeping, stopped, zombie. Any other value is `?`. It is a scheduler state, not a health indicator.

## Load average

`getloadavg` 1/5/15-minute values, labelled "load" and never presented as a CPU percentage.

## Availability

"Unavailable" is never rendered or stored as zero; it shows `—`. Reasons: permission denied, process exited, unsupported, not yet sampled, malformed result, collection failed. A footer count ("N limited") reports rows that were collected partially.

## Memory categories (Phase 2)

Source: `host_statistics64(HOST_VM_INFO64)` and `host_page_size`; page counts are multiplied by the runtime page size (4 KiB or 16 KiB) with overflow checking. Categories are shown separately under their real names:

- **active**, **inactive**, **wired**: as reported by the kernel.
- **compressor**: pages *occupied by* the compressor (physical occupancy), not the logical size of the data compressed into them.
- **free**: the kernel free count minus speculative pages (the same definition `vm_stat` uses); unavailable if that subtraction would underflow.
- **purgeable**, **speculative**, **file-backed** (`external_page_count`): informational; they overlap other categories and are not added to anything.
- No "cached" label is shown: no tested definition exists. A category the OS did not supply shows `—`, never zero.

**Approx. used** = wired + active + compressor (physical). This is a project definition, **not** Activity Monitor's "Memory Used". It is unavailable if any component is missing or the sum overflows. The memory bar and sparkline use Approx. used ÷ `hw.memsize`.

## Swap, uptime, physical memory

- Swap: `vm.swapusage` (total/used). Physical memory: `hw.memsize`, read once.
- Uptime: `now − kern.boottime`, clamped to non-negative. Wall-clock time is used here only because boot time is a wall-clock value.

## Memory pressure

Source: the dispatch memory-pressure source (normal / warning / critical), delivered on a private queue. The source reports **transitions**, not the current level, and events may be coalesced. Therefore:

- The state is **unknown** until the first notification, and a quiet source does not mean "normal".
- The last state is kept with the monotonic time it was observed; the header shows its age ("last notified 1m ago").
- Pressure is never derived from free memory. Behavior has been exercised on the development machine only (macOS 27); macOS 26 (the minimum deployment target) is covered only by the Intel CI test run, not by manual pressure testing.

## CPU topology

`hw.logicalcpu`, `hw.physicalcpu`, `hw.nperflevels`, and `hw.perflevelN.{name,logicalcpu}` are read once at the first sample and cached. Absent keys (Intel, older systems) are expected and show nothing. Level counts do **not** prove which per-core tick entries belong to which level, so per-core bars are labelled **unclassified** and level counts are printed separately using the names the OS reports. Core-class labels would need a validated mapping; none is claimed.

## Sorting

Keys: PID, name, user, CPU, memory, state (`s` cycles, `r` reverses; direction is kept when the key changes). Ties break on PID, then start time, both ascending. Missing values (unavailable user/CPU/memory, unknown state) sort **last in both directions**. Names compare case-insensitively by Unicode scalar value of the lowercased text, independent of locale (so "é" sorts after "z"). State order: running, sleeping, idle, stopped, zombie.

## Filtering

Whitespace-separated terms, AND. A plain term is a case-insensitive substring of the process **name** (command lines are not collected until Phase 3, and no arguments are read just to filter). `pid:N` is an exact positive PID; `user:X` matches the user name (case-insensitive, exact) or a numeric UID; `path:X` is a case-insensitive substring of the available executable path. Predicate prefixes are case-insensitive; no quoting or regular expressions. Filtering applies as you type; an invalid predicate shows an inline error and keeps the last valid filter, Enter commits, Esc restores the filter from before editing, and deleting all text (or Ctrl-U) clears it.

## History and pause

CPU and memory histories are fixed-capacity ring buffers (default 60 samples, clamped to 1…3600) holding timestamps and explicit unavailable samples (drawn as gaps). **Pause** (Space) freezes the presented rows, selection context, and histories; the sampler keeps running, so CPU baselines stay valid. On resume only the newest snapshot is presented: no replay and no filler samples, so the sparklines show a time gap rather than interpolated values. A **STALE** flag appears when no snapshot has arrived for three refresh ticks.

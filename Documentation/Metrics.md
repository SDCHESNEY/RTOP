# Metrics: units, conventions, and what is not claimed

Phase 1 covers process CPU, host CPU, resident memory, state, and load. Memory categories, swap, and pressure arrive in Phase 2 and will be documented here.

## Process CPU %

- Source: `proc_pidinfo(PROC_PIDTASKINFO)` cumulative user + system time, converted from mach absolute time to nanoseconds in the C layer (128-bit intermediate, no overflow).
- Value: `Δ(cpu ns) / Δ(monotonic ns) × 100` between two successive readings of the **same process identity** (PID + start time). 100 means one logical CPU fully busy ("Irix" convention), so a multithreaded process can exceed 100. Normalizing to total capacity is a Phase 4 option.
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

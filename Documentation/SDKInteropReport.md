# SDK Interoperability Report (Phase 0)

Verified against the macOS 27.2 SDK headers on Apple Silicon (arm64), macOS 27.0.1. Wrappers live in `Sources/DarwinSupport`; Swift copies results into owned values before native storage is freed.

| API | Header | Units / contract | Ownership | Failure behavior |
|---|---|---|---|---|
| `proc_listpids(PROC_ALL_PIDS)` | `libproc.h` | Return value and buffer size are **bytes**, not element counts. Divide by `sizeof(pid_t)`. Trailing zero entries are trimmed. | Wrapper `malloc`s, caller frees with `ds_free`. | Not atomic. Sized with 25% slack; a completely filled buffer triggers a retry (max 4), then `DS_RETRY_EXHAUSTED`. |
| `proc_pidinfo(PROC_PIDTBSDINFO)` | `sys/proc_info.h` | Returns bytes written; must equal `sizeof(struct proc_bsdinfo)` or the wrapper reports `DS_SHORT_RESULT`. Start time kept as seconds + microseconds. | Caller-owned stack struct. | `0` return with `errno` (`ESRCH` exited, `EPERM` denied). `errno` captured immediately. |
| `proc_pidinfo(PROC_PIDTASKINFO)` | `sys/proc_info.h` | Same size contract (`proc_taskinfo`). CPU times (`pti_total_user/system`) are in **mach absolute time units**, converted with `mach_timebase_info` using a 128-bit intermediate. | Caller-owned. | As above. |
| `proc_pidpath` | `libproc.h` | Returns path length; wrapper NUL-terminates and clamps. 4096-byte buffer used by Swift. | Caller-owned buffer. | `0` with `errno`. |
| `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | `mach/processor_info.h` | `info_count` is an **element** (`integer_t`) count: `CPU_STATE_MAX` (4) per CPU. Validated before reading. Counters are 32-bit and wrap. | Mach allocates the array out-of-line: released with `vm_deallocate(…, info_count * sizeof(integer_t))` (**bytes**). `mach_host_self()` send right released with `mach_port_deallocate`. | `kern_return_t` reported as `DS_MACH`, kept separate from `errno`. |
| `host_statistics64(HOST_VM_INFO64)` | `mach/vm_statistics.h` | `count` is an element count (`HOST_VM_INFO64_COUNT`). Page size from `host_page_size` (16384 on this machine; never assumed). | Stack struct; host port released. | `DS_MACH`. |
| `sysctlbyname("vm.swapusage")` | `sys/sysctl.h` | `struct xsw_usage`; length checked. | Stack. | `errno`. Swap total was 0 on the dev machine. |
| `sysctlbyname` integers (`hw.memsize`, `hw.nperflevels`) | `sys/sysctl.h` | Size probed first; 4- and 8-byte values handled. | Stack. | Absent keys give `errno` `ENOENT`, treated as expected. |
| `sysctlbyname("kern.boottime")` | `sys/sysctl.h` | `struct timeval`; length checked. Wall clock: display only. | Stack. | `errno`. |
| Signal bridge | `signal.h` | Handler for SIGINT/SIGTERM/SIGHUP/SIGWINCH does only `write(1 byte)` to a nonblocking, close-on-exec pipe and preserves `errno`. A full pipe drops the byte. | Pipe fds owned by C; `ds_signal_bridge_remove` restores previous dispositions. | Install failure rolls back handlers and fds. |

## Observations (dev machine)

- Unprivileged enumeration returned about 890 PIDs. BSD info and task info for the process itself succeed; behavior for other users' processes is not yet characterised (Phase 1 task).
- `leaks --atExit -- rtop --spike-native`: 0 leaks.
- The `repeatedSamplingDoesNotGrowFootprint` test (1,000 probes after warm-up) bounds resident growth under 8 MiB. This is a loose guard only. **A full Instruments Allocations run has not been done.**
- `hw.nperflevels` = 2 here. Per the specification, this does **not** establish which logical CPU indexes are performance vs. efficiency cores; per-core labels stay unclassified.
- Cross-checks: `hw.memsize`, page size and logical CPU count agree with Foundation / `sysctl` / `vm_stat`.
- Swift 6 notes: `vm_page_size`, `mach_task_self_` and the `mach_task_self()` macro are unavailable or unsafe from Swift, so page size is taken in C and process size via `proc_pidinfo`.

## Open items

- Process-exit-during-read and mixed-permission paths need failure injection (Phase 1).
- Instruments Allocations/Leaks over a longer run (Phase 4 gate).
- Validate task-time conversion against `ps`/`top` once CPU deltas exist (Phase 1/2).

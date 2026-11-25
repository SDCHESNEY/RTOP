# Permissions, Visibility, and Signalling

`rtop` runs as the invoking user with no entitlements, no helper, and no privilege escalation. This page records what that means in practice. Only things observed or guaranteed by the code are stated; nothing here is a universal claim about macOS.

## Visibility limits (unprivileged)

- `proc_listpids` lists every process. `proc_pidinfo` (BSD info) is refused with `EPERM` for a share of other users' and system processes; on the development machine this was roughly a third of them. `proc_pidpath` usually still works.
- Such rows are shown as **partial rows**: the identity is PID-only (no start time), and user, parent, state, and CPU are `—`. The footer counts them as "limited".
- Command lines come from `sysctl(KERN_PROCARGS2)`. It is expected to work for the user's own processes and to fail with `EPERM` for others; a failure shows `— (permission denied)`. Zombies can fail with `EINVAL` (shown as "could not be read"). The environment part of the buffer is never decoded or kept.
- Command lines are held in memory only (a 16-entry LRU) and are never logged.

## Signal workflow (`x`)

1. The dialog captures identity (PID + start time), name, UID, executable path, and signal. SIGTERM is the default. Left/Right change the signal and **reset** any confirmation already given.
2. Enter or `y` confirms stage 1. Targets that are root-owned, of unknown owner, or whose executable path has `/System`, `/usr`, or `/sbin` as its leading path *component* need a second stage: an explicit `y` (Enter does not count).
3. Immediately before delivery the controller re-reads the live process. It refuses when the PID is not in `1 < pid <= 99999`, is the monitor itself, has no known start time, has a different start time (`identityChanged`), or has become protected since confirmation (`cautionChanged`: the dialog returns to confirmation as protected).
4. `kill(2)` is called only with a verified positive PID and one of six allow-listed signals (TERM, KILL, INT, HUP, STOP, CONT). `ds_send_signal` also refuses `pid <= 0` in C, so a process group can never be addressed.
5. The outcome is shown as a status line and a refresh is requested at once. "Signal sent" means the kernel accepted the signal. It does **not** mean the process exited: a process can handle or ignore SIGTERM, and a managed service may come back with a new PID and start time.

SIGKILL is never sent automatically; it is always an explicit choice in the dialog.

### Error wording

| Condition | Message (abridged) |
|---|---|
| `EPERM` | "Permission denied: this user may not signal …" |
| `ESRCH` | "… no longer exists; nothing was sent." |
| start time differs | "That PID now belongs to a different process; nothing was sent." |
| start time unreadable | "… cannot be verified …; nothing was sent." |
| other errno | "Sending … failed (errno N)." |

A permission denial is not described as System Integrity Protection or any other specific cause, because `EPERM` alone does not prove one. The monitor never suggests disabling system protections.

## Residual PID race

The start-time check narrows the window in which a reused PID could be signalled, but `kill(2)` takes a PID, so the check and the call are **not atomic**. If the target exits and the kernel hands its PID to a new process in the microseconds between the re-read and the call, the new process receives the signal. The monitor keeps that interval minimal (the effect handler runs synchronously, with no suspension point between the identity read and `kill`) but cannot close it with these interfaces. It does not claim identity-bound delivery.

## GUI apps and services

Observations are deliberately not recorded here until they have been made on real applications. Known design consequences only:

- An accepted SIGTERM to a GUI app or a launchd-managed service may be followed by a restart under a new PID and start time; the old row then disappears and a new one appears.
- SIGSTOP on a GUI app leaves it unresponsive until SIGCONT.

## Tests

Signal tests act only on children the test itself spawned (`posix_spawn`, reaped with `waitpid`, killed in `defer`). Permission-denied handling is covered with mocks, never by signalling real system processes.

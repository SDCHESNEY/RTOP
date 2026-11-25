#ifndef DARWIN_SUPPORT_H
#define DARWIN_SUPPORT_H

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* All functions return 0 on success. On failure they return a nonzero
 * errno-style value (for libproc/sysctl) or a kern_return_t (for Mach calls),
 * captured immediately after the failing call. The two code spaces are
 * reported separately through ds_status_kind. */

typedef enum {
    DS_OK = 0,
    DS_ERRNO = 1,      /* value is an errno */
    DS_MACH = 2,       /* value is a kern_return_t */
    DS_SHORT_RESULT = 3, /* native call returned fewer bytes than the SDK struct */
    DS_NO_MEMORY = 4,
    DS_RETRY_EXHAUSTED = 5
} ds_status_kind;

typedef struct {
    ds_status_kind kind;
    int code;
} ds_status;

/* ---- Process enumeration (libproc) ---- */

/* Allocates *out_pids (caller frees with ds_free). *out_count is an ELEMENT count. */
ds_status ds_list_pids(pid_t **out_pids, int *out_count);
void ds_free(void *ptr);

typedef struct {
    int32_t pid;
    int32_t ppid;
    uint32_t uid;
    uint32_t status;              /* raw SIDL/SRUN/... value from proc_bsdinfo */
    uint64_t start_seconds;
    uint64_t start_microseconds;  /* full native precision preserved */
    char name[64];                /* NUL-terminated, truncated */
} ds_proc_bsd;

typedef struct {
    uint64_t resident_bytes;
    uint64_t virtual_bytes;
    uint64_t user_time_ns;        /* converted from mach absolute time */
    uint64_t system_time_ns;
    int32_t thread_count;
} ds_proc_task;

ds_status ds_proc_bsd_info(pid_t pid, ds_proc_bsd *out);
ds_status ds_proc_task_info(pid_t pid, ds_proc_task *out);
/* Writes a NUL-terminated path; *out_len excludes the NUL. */
ds_status ds_proc_path(pid_t pid, char *buf, size_t capacity, size_t *out_len);

/* ---- CPU (Mach) ---- */

typedef struct {
    uint32_t user, system, idle, nice;
} ds_cpu_ticks;

/* Fills up to `capacity` entries; *out_cpu_count is the number of logical CPUs
 * reported (may exceed capacity; only `capacity` are copied). Mach-allocated
 * storage is released before returning. */
ds_status ds_cpu_ticks_read(ds_cpu_ticks *out, uint32_t capacity, uint32_t *out_cpu_count);

/* ---- Memory ---- */

typedef struct {
    uint64_t page_size_bytes;
    uint64_t free_pages, active_pages, inactive_pages, wire_pages;
    uint64_t speculative_pages, purgeable_pages, external_pages;
    uint64_t compressor_pages;    /* pages occupied by the compressor */
} ds_vm_stats;

ds_status ds_vm_stats_read(ds_vm_stats *out);

typedef struct {
    uint64_t total_bytes, used_bytes, free_bytes;
    uint32_t page_size_bytes;
    int encrypted;
} ds_swap_usage;

ds_status ds_swap_usage_read(ds_swap_usage *out);

/* ---- sysctl ---- */

/* Reads an integer sysctl by name (4- or 8-byte). Absent keys return DS_ERRNO/ENOENT. */
ds_status ds_sysctl_u64(const char *name, uint64_t *out);
/* Reads a string sysctl into buf (NUL-terminated, truncated to capacity-1). *out_len excludes the NUL. */
ds_status ds_sysctl_string(const char *name, char *buf, size_t capacity, size_t *out_len);
ds_status ds_boottime(int64_t *out_seconds, int32_t *out_microseconds);

/* ---- Signal bridge (self-pipe) ----
 * The handler only performs write() of one byte (the signal number) to a
 * nonblocking pipe. If the pipe is full the byte is dropped, which is safe:
 * the reader treats any readable byte as "check state". */

/* Installs handlers for SIGINT, SIGTERM, SIGHUP, SIGWINCH. Returns the read fd
 * via *out_read_fd. Safe to call once; subsequent calls return the same fd. */
ds_status ds_signal_bridge_install(int *out_read_fd);
/* Restores previous dispositions and closes the pipe. */
void ds_signal_bridge_remove(void);

#ifdef __cplusplus
}
#endif

#endif

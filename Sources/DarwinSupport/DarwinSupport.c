#include "DarwinSupport.h"

#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/processor_info.h>
#include <mach/vm_statistics.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <unistd.h>

static ds_status ok(void) { ds_status s = { DS_OK, 0 }; return s; }
static ds_status err_errno(int e) { ds_status s = { DS_ERRNO, e }; return s; }
static ds_status err_mach(kern_return_t kr) { ds_status s = { DS_MACH, (int)kr }; return s; }
static ds_status err_kind(ds_status_kind k) { ds_status s = { k, 0 }; return s; }

void ds_free(void *ptr) { free(ptr); }

/* ---- Process enumeration ---- */

ds_status ds_list_pids(pid_t **out_pids, int *out_count) {
    *out_pids = NULL;
    *out_count = 0;

    /* Enumeration is not atomic: the count can grow between the sizing call and
     * the fill call, so retry a bounded number of times with slack. */
    for (int attempt = 0; attempt < 4; attempt++) {
        int needed = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0); /* BYTES */
        if (needed <= 0) return err_errno(errno ? errno : EIO);

        size_t capacity_bytes = (size_t)needed + (size_t)needed / 4 + 16 * sizeof(pid_t);
        pid_t *buf = malloc(capacity_bytes);
        if (!buf) return err_kind(DS_NO_MEMORY);

        int written = proc_listpids(PROC_ALL_PIDS, 0, buf, (int)capacity_bytes); /* BYTES */
        if (written <= 0) {
            int e = errno ? errno : EIO;
            free(buf);
            return err_errno(e);
        }
        if ((size_t)written < capacity_bytes) {
            int count = written / (int)sizeof(pid_t);
            /* Drop trailing zero entries libproc may leave for vanished slots. */
            while (count > 0 && buf[count - 1] == 0) count--;
            *out_pids = buf;
            *out_count = count;
            return ok();
        }
        free(buf); /* filled completely: may be truncated, retry bigger */
    }
    return err_kind(DS_RETRY_EXHAUSTED);
}

static uint64_t mach_to_ns(uint64_t ticks) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) {
        mach_timebase_info_data_t local;
        if (mach_timebase_info(&local) != KERN_SUCCESS || local.denom == 0) {
            local.numer = 1; local.denom = 1;
        }
        tb = local;
    }
    /* 128-bit intermediate avoids overflow. */
    return (uint64_t)(((__uint128_t)ticks * tb.numer) / tb.denom);
}

ds_status ds_proc_bsd_info(pid_t pid, ds_proc_bsd *out) {
    struct proc_bsdinfo info;
    memset(&info, 0, sizeof info);
    errno = 0;
    int n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, (int)sizeof info);
    if (n <= 0) return err_errno(errno ? errno : ESRCH);
    if (n != (int)sizeof info) return err_kind(DS_SHORT_RESULT);

    memset(out, 0, sizeof *out);
    out->pid = (int32_t)info.pbi_pid;
    out->ppid = (int32_t)info.pbi_ppid;
    out->uid = info.pbi_uid;
    out->status = info.pbi_status;
    out->start_seconds = info.pbi_start_tvsec;
    out->start_microseconds = info.pbi_start_tvusec;
    const char *src = info.pbi_name[0] ? info.pbi_name : info.pbi_comm;
    strlcpy(out->name, src, sizeof out->name);
    return ok();
}

ds_status ds_proc_task_info(pid_t pid, ds_proc_task *out) {
    struct proc_taskinfo info;
    memset(&info, 0, sizeof info);
    errno = 0;
    int n = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, (int)sizeof info);
    if (n <= 0) return err_errno(errno ? errno : ESRCH);
    if (n != (int)sizeof info) return err_kind(DS_SHORT_RESULT);

    out->resident_bytes = info.pti_resident_size;
    out->virtual_bytes = info.pti_virtual_size;
    out->user_time_ns = mach_to_ns(info.pti_total_user);
    out->system_time_ns = mach_to_ns(info.pti_total_system);
    out->thread_count = info.pti_threadnum;
    return ok();
}

ds_status ds_proc_path(pid_t pid, char *buf, size_t capacity, size_t *out_len) {
    if (capacity < 2) return err_errno(EINVAL);
    errno = 0;
    int n = proc_pidpath(pid, buf, (uint32_t)capacity);
    if (n <= 0) return err_errno(errno ? errno : ESRCH);
    size_t len = (size_t)n;
    if (len >= capacity) len = capacity - 1;
    buf[len] = '\0';
    *out_len = len;
    return ok();
}

/* ---- CPU ---- */

ds_status ds_cpu_ticks_read(ds_cpu_ticks *out, uint32_t capacity, uint32_t *out_cpu_count) {
    natural_t cpu_count = 0;
    processor_info_array_t info = NULL;
    mach_msg_type_number_t info_count = 0;

    /* mach_host_self() returns a send right that must be released. */
    mach_port_t host = mach_host_self();
    kern_return_t kr = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO,
                                           &cpu_count, &info, &info_count);
    mach_port_deallocate(mach_task_self(), host);
    if (kr != KERN_SUCCESS) return err_mach(kr);

    /* info_count is an ELEMENT (integer_t) count: CPU_STATE_MAX per CPU. */
    ds_status result = ok();
    if (info_count < cpu_count * CPU_STATE_MAX) {
        result = err_kind(DS_SHORT_RESULT);
    } else {
        for (natural_t i = 0; i < cpu_count && i < capacity; i++) {
            const integer_t *t = &info[i * CPU_STATE_MAX];
            out[i].user = (uint32_t)t[CPU_STATE_USER];
            out[i].system = (uint32_t)t[CPU_STATE_SYSTEM];
            out[i].idle = (uint32_t)t[CPU_STATE_IDLE];
            out[i].nice = (uint32_t)t[CPU_STATE_NICE];
        }
        *out_cpu_count = cpu_count;
    }

    /* Mach-allocated out-of-line memory is released with vm_deallocate (BYTES). */
    vm_deallocate(mach_task_self(), (vm_address_t)info,
                  (vm_size_t)info_count * sizeof(integer_t));
    return result;
}

/* ---- Memory ---- */

ds_status ds_vm_stats_read(ds_vm_stats *out) {
    mach_port_t host = mach_host_self();
    vm_size_t page_size = 0;
    kern_return_t kr = host_page_size(host, &page_size);
    if (kr != KERN_SUCCESS) { mach_port_deallocate(mach_task_self(), host); return err_mach(kr); }

    vm_statistics64_data_t v;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT; /* ELEMENT count */
    kr = host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&v, &count);
    mach_port_deallocate(mach_task_self(), host);
    if (kr != KERN_SUCCESS) return err_mach(kr);

    out->page_size_bytes = page_size;
    out->free_pages = v.free_count;
    out->active_pages = v.active_count;
    out->inactive_pages = v.inactive_count;
    out->wire_pages = v.wire_count;
    out->speculative_pages = v.speculative_count;
    out->purgeable_pages = v.purgeable_count;
    out->external_pages = v.external_page_count;
    out->compressor_pages = v.compressor_page_count;
    return ok();
}

ds_status ds_swap_usage_read(ds_swap_usage *out) {
    struct xsw_usage x;
    size_t len = sizeof x;
    if (sysctlbyname("vm.swapusage", &x, &len, NULL, 0) != 0) return err_errno(errno);
    if (len != sizeof x) return err_kind(DS_SHORT_RESULT);
    out->total_bytes = x.xsu_total;
    out->used_bytes = x.xsu_used;
    out->free_bytes = x.xsu_avail;
    out->page_size_bytes = x.xsu_pagesize;
    out->encrypted = x.xsu_encrypted ? 1 : 0;
    return ok();
}

/* ---- sysctl ---- */

ds_status ds_sysctl_u64(const char *name, uint64_t *out) {
    /* Probe the size first so a 4-byte value is never read through an 8-byte buffer. */
    size_t len = 0;
    if (sysctlbyname(name, NULL, &len, NULL, 0) != 0) return err_errno(errno);
    if (len == sizeof(uint64_t)) {
        uint64_t v = 0;
        if (sysctlbyname(name, &v, &len, NULL, 0) != 0) return err_errno(errno);
        *out = v;
        return ok();
    }
    if (len == sizeof(uint32_t)) {
        uint32_t v = 0;
        if (sysctlbyname(name, &v, &len, NULL, 0) != 0) return err_errno(errno);
        *out = v;
        return ok();
    }
    return err_kind(DS_SHORT_RESULT);
}

ds_status ds_boottime(int64_t *out_seconds, int32_t *out_microseconds) {
    struct timeval tv;
    size_t len = sizeof tv;
    if (sysctlbyname("kern.boottime", &tv, &len, NULL, 0) != 0) return err_errno(errno);
    if (len != sizeof tv) return err_kind(DS_SHORT_RESULT);
    *out_seconds = tv.tv_sec;
    *out_microseconds = tv.tv_usec;
    return ok();
}

/* ---- Signal bridge ---- */

static int g_pipe[2] = { -1, -1 };
static const int k_signals[] = { SIGINT, SIGTERM, SIGHUP, SIGWINCH };
#define K_SIGNAL_COUNT 4
static struct sigaction g_old[K_SIGNAL_COUNT];

static void bridge_handler(int signo) {
    /* Async-signal-safe only: preserve errno, one write(), nothing else. */
    int saved = errno;
    unsigned char b = (unsigned char)signo;
    (void)!write(g_pipe[1], &b, 1); /* EAGAIN when full is intentionally ignored */
    errno = saved;
}

static int set_nonblock_cloexec(int fd) {
    int fl = fcntl(fd, F_GETFL);
    if (fl < 0 || fcntl(fd, F_SETFL, fl | O_NONBLOCK) < 0) return -1;
    int fdfl = fcntl(fd, F_GETFD);
    if (fdfl < 0 || fcntl(fd, F_SETFD, fdfl | FD_CLOEXEC) < 0) return -1;
    return 0;
}

ds_status ds_signal_bridge_install(int *out_read_fd) {
    if (g_pipe[0] >= 0) { *out_read_fd = g_pipe[0]; return ok(); }
    if (pipe(g_pipe) != 0) { int e = errno; g_pipe[0] = g_pipe[1] = -1; return err_errno(e); }
    if (set_nonblock_cloexec(g_pipe[0]) != 0 || set_nonblock_cloexec(g_pipe[1]) != 0) {
        int e = errno;
        close(g_pipe[0]); close(g_pipe[1]);
        g_pipe[0] = g_pipe[1] = -1;
        return err_errno(e);
    }
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = bridge_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    for (int i = 0; i < K_SIGNAL_COUNT; i++) {
        if (sigaction(k_signals[i], &sa, &g_old[i]) != 0) {
            int e = errno;
            for (int j = 0; j < i; j++) sigaction(k_signals[j], &g_old[j], NULL);
            close(g_pipe[0]); close(g_pipe[1]);
            g_pipe[0] = g_pipe[1] = -1;
            return err_errno(e);
        }
    }
    *out_read_fd = g_pipe[0];
    return ok();
}

void ds_signal_bridge_remove(void) {
    if (g_pipe[0] < 0) return;
    for (int i = 0; i < K_SIGNAL_COUNT; i++) sigaction(k_signals[i], &g_old[i], NULL);
    close(g_pipe[0]); close(g_pipe[1]);
    g_pipe[0] = g_pipe[1] = -1;
}

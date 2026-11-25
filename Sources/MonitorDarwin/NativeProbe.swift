import DarwinSupport
import Foundation
import MonitorCore

/// Phase 0 spike: exercises each native call once and reports what it sees.
/// The Phase 1 samplers replace this; the wrappers below are the seed of them.
public struct ProbeReport: Sendable, Equatable {
    public var processCount: Int
    public var ownBSD: ProcessBSD
    public var ownTask: ProcessTask
    public var ownPath: String
    public var logicalCPUCount: Int
    public var physicalMemoryBytes: UInt64
    public var pageSizeBytes: UInt64
    public var freePages: UInt64
    public var wiredPages: UInt64
    public var compressorPages: UInt64
    public var swapTotalBytes: UInt64?
    public var bootTime: Date
    public var perfLevelCount: UInt64?
}

public struct ProcessBSD: Sendable, Equatable {
    public var pid: Int32
    public var ppid: Int32
    public var uid: UInt32
    public var status: UInt32
    public var startSeconds: UInt64
    public var startMicroseconds: UInt64
    public var name: String
}

public struct ProcessTask: Sendable, Equatable {
    public var residentBytes: UInt64
    public var virtualBytes: UInt64
    public var userTimeNanoseconds: UInt64
    public var systemTimeNanoseconds: UInt64
    public var threadCount: Int32
}

public enum NativeProbe {
    public static func listPIDs() throws -> [Int32] {
        var raw: UnsafeMutablePointer<pid_t>?
        var count: Int32 = 0
        if let e = NativeError(ds_list_pids(&raw, &count), operation: "proc_listpids") { throw e }
        defer { ds_free(raw) }
        guard let raw else { return [] }
        // Copy into an owned array before the native buffer is freed.
        return Array(UnsafeBufferPointer(start: raw, count: Int(count)))
    }

    public static func bsdInfo(pid: Int32) throws -> ProcessBSD {
        var out = ds_proc_bsd()
        if let e = NativeError(ds_proc_bsd_info(pid, &out), operation: "proc_pidinfo(BSDINFO)") { throw e }
        let name = withUnsafePointer(to: &out.name) {
            $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
        }
        return ProcessBSD(
            pid: out.pid, ppid: out.ppid, uid: out.uid, status: out.status,
            startSeconds: out.start_seconds, startMicroseconds: out.start_microseconds,
            name: name
        )
    }

    public static func taskInfo(pid: Int32) throws -> ProcessTask {
        var out = ds_proc_task()
        if let e = NativeError(ds_proc_task_info(pid, &out), operation: "proc_pidinfo(TASKINFO)") { throw e }
        return ProcessTask(
            residentBytes: out.resident_bytes, virtualBytes: out.virtual_bytes,
            userTimeNanoseconds: out.user_time_ns, systemTimeNanoseconds: out.system_time_ns,
            threadCount: out.thread_count
        )
    }

    public static func path(pid: Int32) throws -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        var len = 0
        if let e = NativeError(ds_proc_path(pid, &buf, buf.count, &len), operation: "proc_pidpath") { throw e }
        return String(decoding: buf.prefix(len).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Upper bound on bytes read for one process's arguments (the kernel's
    /// `kern.argmax` is typically 1 MiB, including the environment).
    public static let maxProcArgsBytes = 1 << 20

    /// Raw `KERN_PROCARGS2` bytes, bounded. Only the leading argc/path/arguments
    /// are interpreted by `ProcArgsParser`; the environment part is dropped by the caller.
    public static func procArgs(pid: Int32) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: maxProcArgsBytes)
        var length = 0
        if let e = NativeError(ds_proc_args(pid, &buffer, buffer.count, &length), operation: "sysctl(KERN_PROCARGS2)") {
            throw e
        }
        return Array(buffer.prefix(length))
    }

    /// Delivers one signal to one process; `0`/negative PIDs are refused in C.
    /// Returns nil on success, otherwise the errno captured at the call.
    public static func sendSignal(pid: Int32, signal: Int32) -> Int32? {
        let status = ds_send_signal(pid, signal)
        return status.kind == DS_OK ? nil : status.code
    }

    /// Cumulative per-logical-CPU tick counters as (user, system, idle, nice).
    public static func cpuTicks() throws -> [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] {
        var cpuCount: UInt32 = 0
        // First call sizes the result; capacity 0 copies nothing.
        var probe = ds_cpu_ticks()
        if let e = NativeError(ds_cpu_ticks_read(&probe, 0, &cpuCount), operation: "host_processor_info") { throw e }
        var buf = [ds_cpu_ticks](repeating: ds_cpu_ticks(), count: Int(cpuCount))
        var n: UInt32 = 0
        if let e = NativeError(ds_cpu_ticks_read(&buf, cpuCount, &n), operation: "host_processor_info") { throw e }
        return buf.prefix(Int(n)).map { ($0.user, $0.system, $0.idle, $0.nice) }
    }

    // MARK: Memory, uptime, topology (Phase 2)

    public static func memory() throws -> MemoryReading {
        var vm = ds_vm_stats()
        if let e = NativeError(ds_vm_stats_read(&vm), operation: "host_statistics64") { throw e }
        return MemoryReading(
            pageSizeBytes: vm.page_size_bytes,
            freePages: MemoryMath.freePages(kernelFreeCount: vm.free_pages, speculative: vm.speculative_pages),
            activePages: vm.active_pages,
            inactivePages: vm.inactive_pages,
            wiredPages: vm.wire_pages,
            compressorPages: vm.compressor_pages,
            purgeablePages: vm.purgeable_pages,
            speculativePages: vm.speculative_pages,
            fileBackedPages: vm.external_pages
        )
    }

    public static func swap() throws -> SwapReading {
        var swap = ds_swap_usage()
        if let e = NativeError(ds_swap_usage_read(&swap), operation: "vm.swapusage") { throw e }
        return SwapReading(totalBytes: swap.total_bytes, usedBytes: swap.used_bytes, freeBytes: swap.free_bytes)
    }

    public static func physicalMemoryBytes() throws -> UInt64 {
        var value: UInt64 = 0
        if let e = NativeError(ds_sysctl_u64("hw.memsize", &value), operation: "sysctl hw.memsize") { throw e }
        return value
    }

    public static func bootTime() throws -> (seconds: Int64, microseconds: Int32) {
        var sec: Int64 = 0
        var usec: Int32 = 0
        if let e = NativeError(ds_boottime(&sec, &usec), operation: "kern.boottime") { throw e }
        return (sec, usec)
    }

    /// An absent key is expected (Intel, older systems) and yields nil.
    static func sysctlInt(_ name: String) -> Int? {
        var value: UInt64 = 0
        guard NativeError(ds_sysctl_u64(name, &value), operation: name) == nil else { return nil }
        return Int(exactly: value)
    }

    static func sysctlString(_ name: String) -> String? {
        var buf = [CChar](repeating: 0, count: 128)
        var len = 0
        guard NativeError(ds_sysctl_string(name, &buf, buf.count, &len), operation: name) == nil else { return nil }
        return String(decoding: buf.prefix(len).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Reads `hw.perflevel*` once. Counts are reported as the OS gives them;
    /// nothing here maps individual CPUs to a level.
    public static func topology() -> CoreTopology {
        var levels = [CoreTopology.Level]()
        if let count = sysctlInt("hw.nperflevels"), count > 0, count <= 8 {
            for index in 0..<count {
                guard let logical = sysctlInt("hw.perflevel\(index).logicalcpu") else { continue }
                levels.append(.init(index: index, name: sysctlString("hw.perflevel\(index).name"), logicalCPUs: logical))
            }
        }
        return CoreTopology(
            logicalCPUs: sysctlInt("hw.logicalcpu"), physicalCPUs: sysctlInt("hw.physicalcpu"), levels: levels)
    }

    public static func run() throws -> ProbeReport {
        let pid = getpid()
        let pids = try listPIDs()

        var vm = ds_vm_stats()
        if let e = NativeError(ds_vm_stats_read(&vm), operation: "host_statistics64") { throw e }

        var memsize: UInt64 = 0
        if let e = NativeError(ds_sysctl_u64("hw.memsize", &memsize), operation: "sysctl hw.memsize") { throw e }

        var swap = ds_swap_usage()
        let swapTotal: UInt64? = NativeError(ds_swap_usage_read(&swap), operation: "vm.swapusage") == nil
            ? swap.total_bytes : nil

        var sec: Int64 = 0
        var usec: Int32 = 0
        if let e = NativeError(ds_boottime(&sec, &usec), operation: "kern.boottime") { throw e }

        // Absent on Intel and older systems; treated as expected, not an error.
        var levels: UInt64 = 0
        let perf: UInt64? = NativeError(ds_sysctl_u64("hw.nperflevels", &levels), operation: "hw.nperflevels") == nil
            ? levels : nil

        return ProbeReport(
            processCount: pids.count,
            ownBSD: try bsdInfo(pid: pid),
            ownTask: try taskInfo(pid: pid),
            ownPath: try path(pid: pid),
            logicalCPUCount: try cpuTicks().count,
            physicalMemoryBytes: memsize,
            pageSizeBytes: vm.page_size_bytes,
            freePages: vm.free_pages,
            wiredPages: vm.wire_pages,
            compressorPages: vm.compressor_pages,
            swapTotalBytes: swapTotal,
            bootTime: Date(timeIntervalSince1970: TimeInterval(sec) + TimeInterval(usec) / 1_000_000),
            perfLevelCount: perf
        )
    }
}

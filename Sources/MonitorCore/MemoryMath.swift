/// Pure memory and uptime arithmetic. All operations are checked: overflow or
/// a missing component yields nil rather than a wrapped or zero value.
/// Definitions are documented in Documentation/Metrics.md.
public enum MemoryMath {
    /// Bytes for a page count, or nil if the count is missing or the product overflows.
    public static func bytes(pages: UInt64?, pageSize: UInt64) -> UInt64? {
        guard let pages else { return nil }
        let (product, overflow) = pages.multipliedReportingOverflow(by: pageSize)
        return overflow ? nil : product
    }

    /// Project-defined headline estimate: wired + active + compressor
    /// (physical occupancy). Not Activity Monitor's "Memory Used". Unavailable
    /// if any component is missing.
    public static func approximateUsedBytes(_ reading: MemoryReading) -> UInt64? {
        let components = [reading.wiredPages, reading.activePages, reading.compressorPages]
        var total: UInt64 = 0
        for pages in components {
            guard let bytes = bytes(pages: pages, pageSize: reading.pageSizeBytes) else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }

    /// Pages free in the `vm_stat` sense: the kernel's free count includes
    /// speculative pages, which are reported as their own category. Nil if the
    /// subtraction would underflow (inconsistent counters).
    public static func freePages(kernelFreeCount: UInt64, speculative: UInt64) -> UInt64? {
        kernelFreeCount >= speculative ? kernelFreeCount - speculative : nil
    }

    /// `part / total` clamped to 0...1; nil when `total` is zero.
    public static func fraction(_ part: UInt64, of total: UInt64) -> Double? {
        guard total > 0 else { return nil }
        return min(1, Double(part) / Double(total))
    }

    /// Seconds since boot, never negative (a clock stepped behind the boot time clamps to 0).
    public static func uptimeSeconds(bootSeconds: Int64, bootMicroseconds: Int32, now: Double) -> Double {
        let boot = Double(bootSeconds) + Double(bootMicroseconds) / 1_000_000
        return max(0, now - boot)
    }
}

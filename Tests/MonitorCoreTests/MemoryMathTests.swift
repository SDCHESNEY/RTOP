import Testing
@testable import MonitorCore

@Suite struct MemoryMathTests {
    private func reading(
        page: UInt64 = 16384, wired: UInt64? = 100, active: UInt64? = 200, compressor: UInt64? = 50
    ) -> MemoryReading {
        MemoryReading(pageSizeBytes: page, activePages: active, wiredPages: wired, compressorPages: compressor)
    }

    @Test func approximateUsedIsWiredPlusActivePlusCompressor() {
        #expect(MemoryMath.approximateUsedBytes(reading()) == 350 * 16384)
    }

    @Test func pageSizeVariations() {
        #expect(MemoryMath.approximateUsedBytes(reading(page: 4096)) == 350 * 4096)
        #expect(MemoryMath.approximateUsedBytes(reading(page: 16384)) == 350 * 16384)
    }

    @Test func anyMissingComponentMakesItUnavailable() {
        #expect(MemoryMath.approximateUsedBytes(reading(wired: nil)) == nil)
        #expect(MemoryMath.approximateUsedBytes(reading(active: nil)) == nil)
        #expect(MemoryMath.approximateUsedBytes(reading(compressor: nil)) == nil)
    }

    @Test func missingCategoryIsNotZero() {
        #expect(MemoryMath.bytes(pages: nil, pageSize: 4096) == nil)
        #expect(MemoryMath.bytes(pages: 0, pageSize: 4096) == 0)
    }

    @Test func overflowIsDetectedNotWrapped() {
        #expect(MemoryMath.bytes(pages: UInt64.max, pageSize: 16384) == nil)
        #expect(MemoryMath.approximateUsedBytes(reading(wired: UInt64.max / 16384 - 1000)) != nil)
        let huge = UInt64.max / 16384
        #expect(MemoryMath.approximateUsedBytes(reading(wired: huge, active: huge, compressor: huge)) == nil)
    }

    @Test func freePagesExcludeSpeculativeAndNeverUnderflow() {
        #expect(MemoryMath.freePages(kernelFreeCount: 1000, speculative: 200) == 800)
        #expect(MemoryMath.freePages(kernelFreeCount: 200, speculative: 200) == 0)
        #expect(MemoryMath.freePages(kernelFreeCount: 100, speculative: 200) == nil)
    }

    @Test func fractionIsClampedAndNilForZeroTotal() {
        #expect(MemoryMath.fraction(50, of: 200) == 0.25)
        #expect(MemoryMath.fraction(500, of: 200) == 1)
        #expect(MemoryMath.fraction(0, of: 200) == 0)
        #expect(MemoryMath.fraction(10, of: 0) == nil)
    }

    @Test func uptimeIsNeverNegative() {
        #expect(MemoryMath.uptimeSeconds(bootSeconds: 1000, bootMicroseconds: 500_000, now: 1100.5) == 100)
        #expect(MemoryMath.uptimeSeconds(bootSeconds: 1000, bootMicroseconds: 0, now: 900) == 0)
    }
}

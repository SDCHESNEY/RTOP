import Testing
@testable import MonitorCore

@Suite struct HistoryBufferTests {
    @Test func startsEmptyAndFillsToCapacity() {
        var h = HistoryBuffer<Double>(capacity: 3)
        #expect(h.count == 0 && h.samples.isEmpty)
        h.append(.value(1), atNanoseconds: 10)
        h.append(.value(2), atNanoseconds: 20)
        #expect(h.samples.map(\.value) == [.value(1), .value(2)])
    }

    @Test func wrapsOverwritingTheOldestAndKeepsOrder() {
        var h = HistoryBuffer<Double>(capacity: 3)
        for i in 1...7 { h.append(.value(Double(i)), atNanoseconds: UInt64(i)) }
        #expect(h.count == 3)
        #expect(h.samples.map(\.value) == [.value(5), .value(6), .value(7)])
        #expect(h.samples.map(\.atNanoseconds) == [5, 6, 7])
    }

    @Test func storageNeverExceedsCapacity() {
        var h = HistoryBuffer<Double>(capacity: 60)
        for i in 0..<10_000 { h.append(.value(Double(i)), atNanoseconds: UInt64(i)) }
        #expect(h.count == 60)
        #expect(h.samples.first?.value == .value(9940))
        #expect(h.samples.last?.value == .value(9999))
    }

    @Test func unavailableSamplesAreKeptExplicitlyNotAsZero() {
        var h = HistoryBuffer<Double>(capacity: 4)
        h.append(.value(10), atNanoseconds: 1)
        h.append(.unavailable(.notYetSampled), atNanoseconds: 2)
        h.append(.value(30), atNanoseconds: 3)
        #expect(h.samples.map(\.value) == [.value(10), .unavailable(.notYetSampled), .value(30)])
    }

    @Test func capacityIsClamped() {
        #expect(HistoryBuffer<Double>(capacity: 0).capacity == 1)
        #expect(HistoryBuffer<Double>(capacity: -5).capacity == 1)
        #expect(HistoryBuffer<Double>(capacity: 1_000_000).capacity == 3600)
        var one = HistoryBuffer<Double>(capacity: 1)
        one.append(.value(1), atNanoseconds: 1)
        one.append(.value(2), atNanoseconds: 2)
        #expect(one.samples.map(\.value) == [.value(2)])
    }

    @Test func recentReturnsTheNewestSamplesOldestFirst() {
        var h = HistoryBuffer<Double>(capacity: 5)
        for i in 1...8 { h.append(.value(Double(i)), atNanoseconds: UInt64(i)) }
        #expect(h.recent(2).map(\.value) == [.value(7), .value(8)])
        #expect(h.recent(99).count == 5)
        #expect(h.recent(0).isEmpty)
        #expect(h.recent(-1).isEmpty)
    }
}

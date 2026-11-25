import Testing
@testable import MonitorCore

@Suite struct ModelsTests {
    @Test func samePIDWithDifferentStartIsADifferentProcess() {
        #expect(Fixtures.identity(42, start: 1) != Fixtures.identity(42, start: 2))
        #expect(Fixtures.identity(42, start: 1) == Fixtures.identity(42, start: 1))
        #expect(Set([Fixtures.identity(42, start: 1), Fixtures.identity(42, start: 2)]).count == 2)
    }

    @Test func startTimeKeepsMicrosecondPrecision() {
        let a = ProcessStartTime(seconds: 5, microseconds: 1)
        let b = ProcessStartTime(seconds: 5, microseconds: 2)
        #expect(a != b)
        #expect(a < b)
    }

    @Test func availabilityExposesValueOrReason() {
        let v: Availability<Int> = .value(3)
        let u: Availability<Int> = .unavailable(.permissionDenied)
        #expect(v.value == 3)
        #expect(v.unavailableReason == nil)
        #expect(u.value == nil)
        #expect(u.unavailableReason == .permissionDenied)
        #expect(v.map { $0 * 2 } == .value(6))
        #expect(u.map { $0 * 2 } == .unavailable(.permissionDenied))
    }

    @Test func unavailableIsNeverEqualToZero() {
        let zero: Availability<Double> = .value(0)
        #expect(zero != .unavailable(.notYetSampled))
    }
}

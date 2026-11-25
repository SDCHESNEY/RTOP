import Testing
@testable import MonitorCore

/// Deterministic generator so the property tests are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 { // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct ProcessSortTests {
    private func pids(_ rows: [ProcessSummary]) -> [Int32] { rows.map(\.identity.pid) }

    @Test func pidSortsBothDirections() {
        let rows = [Fixtures.process(3), Fixtures.process(1), Fixtures.process(2)]
        #expect(pids(ProcessSort.sorted(rows, by: .pid, descending: false)) == [1, 2, 3])
        #expect(pids(ProcessSort.sorted(rows, by: .pid, descending: true)) == [3, 2, 1])
    }

    @Test func nameIsCaseInsensitiveAndTiesBreakOnPIDAscending() {
        let rows = [
            Fixtures.process(5, name: "zed"), Fixtures.process(4, name: "Alpha"),
            Fixtures.process(2, name: "alpha"), Fixtures.process(3, name: "beta"),
        ]
        #expect(pids(ProcessSort.sorted(rows, by: .name, descending: false)) == [2, 4, 3, 5])
        // Descending reverses the key order but ties still break on ascending PID.
        #expect(pids(ProcessSort.sorted(rows, by: .name, descending: true)) == [5, 3, 2, 4])
    }

    @Test func nameOrderIsByScalarValueNotLocale() {
        let rows = [Fixtures.process(1, name: "éclair"), Fixtures.process(2, name: "zebra"), Fixtures.process(3, name: "apple")]
        // "é" (U+00E9) sorts after "z" by scalar value, in every locale.
        #expect(pids(ProcessSort.sorted(rows, by: .name, descending: false)) == [3, 2, 1])
    }

    @Test func missingValuesSortLastInBothDirections() {
        let rows = [
            Fixtures.process(1, cpu: nil), Fixtures.process(2, cpu: 5), Fixtures.process(3, cpu: 50),
            Fixtures.process(4, cpu: nil),
        ]
        #expect(pids(ProcessSort.sorted(rows, by: .cpu, descending: false)) == [2, 3, 1, 4])
        #expect(pids(ProcessSort.sorted(rows, by: .cpu, descending: true)) == [3, 2, 1, 4])
    }

    @Test func missingUserAndMemoryAndUnknownStateSortLast() {
        let rows = [
            Fixtures.process(1, resident: nil, user: nil, status: .unknown),
            Fixtures.process(2, resident: 100, user: "bob", status: .running),
            Fixtures.process(3, resident: 200, user: "amy", status: .zombie),
        ]
        for descending in [false, true] {
            #expect(ProcessSort.sorted(rows, by: .user, descending: descending).last?.identity.pid == 1)
            #expect(ProcessSort.sorted(rows, by: .memory, descending: descending).last?.identity.pid == 1)
            #expect(ProcessSort.sorted(rows, by: .state, descending: descending).last?.identity.pid == 1)
        }
        #expect(pids(ProcessSort.sorted(rows, by: .user, descending: false)) == [3, 2, 1])
        #expect(pids(ProcessSort.sorted(rows, by: .memory, descending: true)) == [3, 2, 1])
        #expect(pids(ProcessSort.sorted(rows, by: .state, descending: false)) == [2, 3, 1])
    }

    @Test func equalPIDsTieBreakOnStartIdentity() {
        let rows = [Fixtures.process(7, start: 300), Fixtures.process(7, start: 100), Fixtures.process(7, start: 200)]
        let sorted = ProcessSort.sorted(rows, by: .cpu, descending: true)
        #expect(sorted.map(\.identity.start?.seconds) == [100, 200, 300])
    }

    @Test func sortingIsStableForEqualRowsAndDeterministic() {
        var generator = SeededGenerator(seed: 42)
        let rows = (1...200).map {
            Fixtures.process(Int32($0), cpu: Bool.random(using: &generator) ? nil : Double(Int.random(in: 0...5, using: &generator)))
        }
        for key in SortKey.allCases {
            let a = ProcessSort.sorted(rows, by: key, descending: false)
            let b = ProcessSort.sorted(rows.reversed(), by: key, descending: false)
            #expect(a == b, "input order must not matter for \(key)")
        }
    }

    @Test func sortPreservesTheSetOfIdentities() {
        var generator = SeededGenerator(seed: 7)
        let names = ["a", "B", "c", "é", "日本", ""]
        for _ in 0..<20 {
            let rows = (0..<100).map { i in
                Fixtures.process(
                    Int32(i + 1), start: UInt64.random(in: 1...3, using: &generator),
                    name: names.randomElement(using: &generator) ?? "",
                    cpu: Bool.random(using: &generator) ? nil : Double.random(in: 0...400, using: &generator),
                    user: Bool.random(using: &generator) ? nil : "u\(Int.random(in: 0...3, using: &generator))")
            }
            for key in SortKey.allCases {
                for descending in [false, true] {
                    let sorted = ProcessSort.sorted(rows, by: key, descending: descending)
                    #expect(Set(sorted.map(\.identity)) == Set(rows.map(\.identity)))
                    #expect(sorted.count == rows.count)
                }
            }
        }
    }

    @Test func sortKeyCyclesThroughEveryKeyAndWraps() {
        var key = SortKey.pid
        var seen = [key]
        for _ in 0..<SortKey.allCases.count - 1 { key = key.next; seen.append(key) }
        #expect(seen == SortKey.allCases)
        #expect(key.next == .pid)
    }
}

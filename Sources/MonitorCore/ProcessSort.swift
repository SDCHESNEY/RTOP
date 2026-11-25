public enum SortKey: Sendable, Equatable, CaseIterable {
    case pid, name, user, cpu, memory, state

    /// Next key for the `s` binding, wrapping around.
    public var next: SortKey {
        let all = SortKey.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Deterministic process ordering.
///
/// - Ties break on PID, then start time, always ascending (the PID key itself follows the direction).
/// - A missing value (unavailable, or an unknown state) sorts last in both directions.
/// - Names compare case-insensitively by Unicode scalar value of the lowercased
///   text, which does not depend on the user's locale.
/// - State order (ascending): running, sleeping, idle, stopped, zombie.
public enum ProcessSort {
    public static func sorted(_ rows: [ProcessSummary], by key: SortKey, descending: Bool) -> [ProcessSummary] {
        rows.sorted { precedes($0, $1, key: key, descending: descending) }
    }

    public static func precedes(_ a: ProcessSummary, _ b: ProcessSummary, key: SortKey, descending: Bool) -> Bool {
        switch key {
        case .pid: if a.identity.pid != b.identity.pid { return descending ? a.identity.pid > b.identity.pid : a.identity.pid < b.identity.pid }
        case .name: if let r = compare(foldedName(a.name), foldedName(b.name), descending, scalarsLess) { return r }
        case .user: if let r = compare(a.userName.value.map(foldedName), b.userName.value.map(foldedName), descending, scalarsLess) { return r }
        case .cpu: if let r = compare(a.cpuPercent.value, b.cpuPercent.value, descending, <) { return r }
        case .memory: if let r = compare(a.residentBytes.value, b.residentBytes.value, descending, <) { return r }
        case .state: if let r = compare(rank(a.status), rank(b.status), descending, <) { return r }
        }
        return tieBreak(a.identity, b.identity)
    }

    // MARK: Comparison helpers

    /// nil = tie (fall through to the tie-break); otherwise the final answer.
    private static func compare<T>(_ a: T?, _ b: T?, _ descending: Bool, _ less: (T, T) -> Bool) -> Bool? {
        switch (a, b) {
        case (nil, nil): return nil
        case (nil, _): return false // missing sorts last in both directions
        case (_, nil): return true
        case let (x?, y?):
            if less(x, y) { return !descending }
            if less(y, x) { return descending }
            return nil
        }
    }

    private static func tieBreak(_ a: ProcessIdentity, _ b: ProcessIdentity) -> Bool {
        if a.pid != b.pid { return a.pid < b.pid }
        switch (a.start, b.start) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case let (x?, y?): return x < y
        }
    }

    private static func foldedName(_ name: String) -> String { name.lowercased() }

    private static func scalarsLess(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) { $0.value < $1.value }
    }

    private static func rank(_ status: ProcessStatus) -> Int? {
        switch status {
        case .running: 0
        case .sleeping: 1
        case .idle: 2
        case .stopped: 3
        case .zombie: 4
        case .unknown: nil
        }
    }
}

import MonitorCore

enum ViewFixtures {
    static func row(
        _ pid: Int32, _ name: String, user: String? = "shawn", cpu: Double? = nil, rss: UInt64? = nil,
        status: ProcessStatus = .sleeping
    ) -> ProcessSummary {
        ProcessSummary(
            identity: ProcessIdentity(pid: pid, start: ProcessStartTime(seconds: 1, microseconds: UInt64(pid))),
            parentPID: .value(1), name: name, uid: .value(501),
            userName: user.map { .value($0) } ?? .unavailable(.permissionDenied),
            cpuPercent: cpu.map { .value($0) } ?? .unavailable(.notYetSampled),
            residentBytes: rss.map { .value($0) } ?? .unavailable(.permissionDenied),
            status: status, executablePath: .value("/x/\(name)")
        )
    }

    /// Deterministic snapshot used by the golden tests.
    static let rows: [ProcessSummary] = [
        row(1, "launchd", user: "root", cpu: 0.0, rss: 12_345_678, status: .running),
        row(98, "logd", user: "root", cpu: 0.3, rss: 8_000_000),
        row(412, "Safari", cpu: 12.34, rss: 512 * 1024 * 1024),
        row(777, "kernel_task", user: nil, cpu: nil, rss: nil, status: .unknown),
        row(1234, "Xcode", cpu: 145.67, rss: 3 * 1024 * 1024 * 1024, status: .running),
        row(2000, "日本語アプリ", cpu: 1.0, rss: 4096, status: .stopped),
    ]

    static func state(size: TerminalSize, rows: [ProcessSummary] = ViewFixtures.rows, selecting index: Int? = 0) -> AppState {
        var state = AppState(terminalSize: size)
        let snapshot = Snapshot(
            sequence: 1, processes: rows,
            cpu: .value(CPUReading(aggregatePercent: 12.5, perCorePercent: [10, 15])),
            load: .value(LoadAverage(one: 1.5, five: 2.25, fifteen: 3)),
            warnings: [CollectionWarning(reason: .permissionDenied, count: 1)]
        )
        _ = Reducer.reduce(&state, .snapshot(snapshot))
        if let index, index > 0 { for _ in 0..<index { _ = Reducer.reduce(&state, .key(.down)) } }
        return state
    }
}

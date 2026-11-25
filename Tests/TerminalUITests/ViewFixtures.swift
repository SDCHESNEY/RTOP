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

    /// 16 GiB machine with 16 KiB pages; categories chosen to be round numbers.
    static let memory = MemoryReading(
        pageSizeBytes: 16384, freePages: 32768, activePages: 262_144, inactivePages: 196_608,
        wiredPages: 131_072, compressorPages: 65536, purgeablePages: 6400, speculativePages: 12_800,
        fileBackedPages: 81920)

    static func snapshot(
        sequence: UInt64, rows: [ProcessSummary] = ViewFixtures.rows, capturedAt: UInt64 = 12_000_000_000,
        cpu: Availability<CPUReading> = .value(CPUReading(aggregatePercent: 12.5, perCorePercent: [0, 25, 60, 100])),
        memory: Availability<MemoryReading> = .value(ViewFixtures.memory),
        pressure: MemoryPressureReading = MemoryPressureReading(state: .normal, observedAtNanoseconds: 2_000_000_000)
    ) -> Snapshot {
        Snapshot(
            sequence: sequence, capturedAtNanoseconds: capturedAt, processes: rows, cpu: cpu,
            load: .value(LoadAverage(one: 1.5, five: 2.25, fifteen: 3)),
            memory: memory,
            swap: .value(SwapReading(totalBytes: 2 << 30, usedBytes: 0, freeBytes: 2 << 30)),
            pressure: pressure,
            physicalMemoryBytes: .value(16 << 30),
            uptimeSeconds: .value(100_000),
            topology: .value(CoreTopology(
                logicalCPUs: 12, physicalCPUs: 12,
                levels: [.init(index: 0, name: "Performance", logicalCPUs: 8),
                         .init(index: 1, name: "Efficiency", logicalCPUs: 4)])),
            warnings: [CollectionWarning(reason: .permissionDenied, count: 1)]
        )
    }

    static func state(size: TerminalSize, rows: [ProcessSummary] = ViewFixtures.rows, selecting index: Int? = 0) -> AppState {
        var state = AppState(terminalSize: size)
        _ = Reducer.reduce(&state, .snapshot(snapshot(sequence: 1, rows: rows)))
        if let index, index > 0 { for _ in 0..<index { _ = Reducer.reduce(&state, .key(.down)) } }
        return state
    }
}

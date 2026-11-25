import MonitorCore

enum Fixtures {
    static func identity(_ pid: Int32, start: UInt64 = 100) -> ProcessIdentity {
        ProcessIdentity(pid: pid, start: ProcessStartTime(seconds: start, microseconds: 0))
    }

    static func process(
        _ pid: Int32, start: UInt64 = 100, name: String = "proc", cpu: Double? = nil, resident: UInt64? = nil
    ) -> ProcessSummary {
        ProcessSummary(
            identity: identity(pid, start: start),
            parentPID: .value(1),
            name: name,
            uid: .value(501),
            userName: .value("user"),
            cpuPercent: cpu.map { .value($0) } ?? .unavailable(.notYetSampled),
            residentBytes: resident.map { .value($0) } ?? .unavailable(.permissionDenied),
            status: .sleeping,
            executablePath: .value("/bin/\(name)")
        )
    }

    static func snapshot(_ sequence: UInt64, _ processes: [ProcessSummary]) -> Snapshot {
        Snapshot(sequence: sequence, processes: processes)
    }
}

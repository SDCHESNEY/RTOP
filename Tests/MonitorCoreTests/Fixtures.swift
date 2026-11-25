import MonitorCore

enum Fixtures {
    static func identity(_ pid: Int32, start: UInt64 = 100) -> ProcessIdentity {
        ProcessIdentity(pid: pid, start: ProcessStartTime(seconds: start, microseconds: 0))
    }

    static func process(
        _ pid: Int32, start: UInt64 = 100, name: String = "proc", cpu: Double? = nil, resident: UInt64? = nil,
        user: String? = "user", uid: UInt32 = 501, status: ProcessStatus = .sleeping, path: String? = nil
    ) -> ProcessSummary {
        ProcessSummary(
            identity: identity(pid, start: start),
            parentPID: .value(1),
            name: name,
            uid: .value(uid),
            userName: user.map { .value($0) } ?? .unavailable(.permissionDenied),
            cpuPercent: cpu.map { .value($0) } ?? .unavailable(.notYetSampled),
            residentBytes: resident.map { .value($0) } ?? .unavailable(.permissionDenied),
            status: status,
            executablePath: .value(path ?? "/bin/\(name)")
        )
    }

    static func snapshot(_ sequence: UInt64, _ processes: [ProcessSummary]) -> Snapshot {
        Snapshot(sequence: sequence, processes: processes)
    }
}

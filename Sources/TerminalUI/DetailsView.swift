import Foundation
import MonitorCore

/// The detail pane: replaces the process table below the overview. Pure.
enum DetailsView {
    private static let labelWidth = 9

    static func reasonText(_ reason: UnavailableReason) -> String {
        switch reason {
        case .permissionDenied: "permission denied"
        case .processExited: "process exited"
        case .unsupported: "unsupported"
        case .notYetSampled: "not yet sampled"
        case .malformed: "unreadable data"
        case .collectionFailed: "could not be read"
        }
    }

    private static func show<T>(_ value: Availability<T>, _ format: (T) -> String) -> String where T: Sendable & Equatable {
        switch value {
        case .value(let v): TextSanitizer.sanitize(format(v))
        case .unavailable(let reason): "\(ProcessTableView.unavailableGlyph) (\(reasonText(reason)))"
        }
    }

    private static func timestamp(_ start: ProcessStartTime) -> String {
        let formatter = ISO8601DateFormatter() // UTC, so output does not depend on the machine's zone
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(start.seconds)))
    }

    static func draw(_ buffer: inout CellBuffer, _ state: AppState, _ options: RenderOptions) {
        guard let pane = state.detailPane else { return }
        let size = TerminalSize(columns: buffer.columns, rows: buffer.rows)
        let headerY = ProcessTableLayout.overviewRows(for: size)
        let first = headerY + ProcessTableLayout.headerRows
        let last = buffer.rows - ProcessTableLayout.footerRows // exclusive

        let process = state.rows.first { $0.identity == pane.identity }
        let title = "DETAILS  pid \(pane.identity.pid)  " + TextSanitizer.sanitize(process?.name ?? "")
        let headStyle = Style(bold: true, underline: true)
        buffer.fillRow(headerY, style: headStyle)
        buffer.write(title, x: 0, y: headerY, style: headStyle)

        var lines = [(String, String)]()
        if let process {
            lines.append(("Name", TextSanitizer.sanitize(process.name)))
            lines.append(("Parent", show(process.parentPID) { parentText($0, state) }))
            lines.append(("User", show(process.userName) { name in
                process.uid.value.map { "\(name) (uid \($0))" } ?? name
            }))
            lines.append(("State", "\(process.status)"))
            lines.append(("Started", pane.identity.start.map(timestamp) ?? "\(ProcessTableView.unavailableGlyph) (could not be read)"))
            lines.append(("CPU %", state.displayedCPUPercent(process).map {
                String(format: "%.1f", $0) + (state.normalizeCPU ? " (share of all CPUs)" : " (100 = one core)")
            } ?? "\(ProcessTableView.unavailableGlyph) (unavailable)"))
            lines.append(("Resident", show(process.residentBytes, ByteFormat.short)))
        }
        guard let details = pane.details else {
            lines.append(("Details", "Loading…"))
            write(lines, command: nil, in: &buffer, from: first, to: last, options: options)
            return
        }
        lines.append(("Virtual", show(details.virtualBytes, ByteFormat.short)))
        lines.append(("Threads", show(details.threadCount) { String($0) }))
        lines.append(("Path", process.map { show($0.executablePath) { $0 } } ?? ProcessTableView.unavailableGlyph))
        write(lines, command: details.commandLine, in: &buffer, from: first, to: last, options: options)
    }

    private static func parentText(_ ppid: Int32, _ state: AppState) -> String {
        let name = state.snapshot?.processes.first { $0.identity.pid == ppid }?.name
        return name.map { "\(ppid) (\(TextSanitizer.sanitize($0)))" } ?? String(ppid)
    }

    private static func write(
        _ lines: [(String, String)], command: Availability<ProcessDetails.CommandLine>?,
        in buffer: inout CellBuffer, from first: Int, to last: Int, options: RenderOptions
    ) {
        var y = first
        let valueX = labelWidth + 1
        let valueWidth = max(1, buffer.columns - valueX)
        func put(_ label: String, _ value: String) {
            guard y < last else { return }
            buffer.write(label, x: 0, y: y, style: Style(bold: true), maxColumns: labelWidth)
            buffer.write(DisplayWidth.truncate(value, toColumns: valueWidth, ellipsis: true), x: valueX, y: y)
            y += 1
        }
        for (label, value) in lines { put(label, value) }

        guard let command else { return }
        switch command {
        case .unavailable(let reason):
            put("Command", "\(ProcessTableView.unavailableGlyph) (\(reasonText(reason)))")
        case .value(let line):
            var text = line.arguments.map(TextSanitizer.sanitize).joined(separator: " ")
            if line.truncated { text += " …(truncated)" }
            let wrapped = wrap(text, width: valueWidth)
            for (i, part) in wrapped.enumerated() {
                guard y < last else { return }
                let isLastAvailable = y == last - 1 && i < wrapped.count - 1
                put(i == 0 ? "Command" : "", isLastAvailable ? DisplayWidth.truncate(part + "…", toColumns: valueWidth, ellipsis: true) : part)
            }
        }
    }

    /// Hard wrap on column width (command lines have no reliable break points).
    static func wrap(_ text: String, width: Int) -> [String] {
        guard width > 0, !text.isEmpty else { return [text] }
        var out = [String]()
        var current = ""
        var used = 0
        for ch in text {
            let w = DisplayWidth.of(ch)
            if used + w > width {
                out.append(current)
                current = ""
                used = 0
            }
            current.append(ch)
            used += w
        }
        out.append(current)
        return out
    }
}

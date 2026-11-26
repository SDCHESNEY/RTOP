import Foundation
import MonitorCore

/// Header panels: title line, CPU, per-core, memory, categories, swap/pressure.
/// Pure drawing into a `CellBuffer`; every OS-derived string is sanitized.
enum OverviewView {
    static func draw(_ buffer: inout CellBuffer, _ state: AppState, _ options: RenderOptions) {
        let full = ProcessTableLayout.overviewRows(for: TerminalSize(columns: buffer.columns, rows: buffer.rows))
            == ProcessTableLayout.fullOverviewRows
        drawTitle(&buffer, state, full: full)
        guard full else { return }
        let snapshot = state.snapshot
        drawCPU(&buffer, state, snapshot, options, y: 1)
        drawCores(&buffer, snapshot, options, y: 2)
        drawMemory(&buffer, state, snapshot, options, y: 3)
        drawCategories(&buffer, snapshot, y: 4)
        drawPurgeableEtc(&buffer, snapshot, y: 5)
        drawSwapAndPressure(&buffer, snapshot, options, y: 6)
    }

    static let unavailable = ProcessTableView.unavailableGlyph

    // MARK: Title

    private static func drawTitle(_ buffer: inout CellBuffer, _ state: AppState, full: Bool) {
        let style = Style(bold: true)
        buffer.fillRow(0, style: style)
        var parts = ["rtop"]
        if let snapshot = state.snapshot {
            let total = snapshot.processes.count
            parts.append(state.filter.isEmpty ? "\(total) processes" : "\(state.rows.count) of \(total) processes")
            if full {
                if let uptime = snapshot.uptimeSeconds.value { parts.append("up " + durationText(uptime)) }
            } else if let cpu = snapshot.cpu.value {
                parts.append("CPU " + String(format: "%.1f%%", cpu.aggregatePercent))
            }
            if let load = snapshot.load.value {
                parts.append("load " + String(format: "%.2f %.2f %.2f", load.one, load.five, load.fifteen))
            }
        } else {
            parts.append("collecting…")
        }

        var flags = [String]()
        if state.isPaused { flags.append("PAUSED") }
        if state.isStale { flags.append("STALE") }
        let flagText = flags.joined(separator: " ")
        let reserved = flagText.isEmpty ? 0 : flagText.count + 2
        buffer.write(parts.joined(separator: "  "), x: 0, y: 0, style: style, maxColumns: buffer.columns - reserved)
        if !flagText.isEmpty {
            buffer.write(flagText, x: buffer.columns - flagText.count, y: 0, style: Style(bold: true, inverse: true))
        }
    }

    /// "3d 4h", "4h 05m", "12m", "30s". Never negative.
    static func durationText(_ seconds: Double) -> String {
        let total = Int(min(max(seconds, 0), 1e9))
        let days = total / 86_400, hours = total % 86_400 / 3600, minutes = total % 3600 / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h " + String(format: "%02dm", minutes) }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total % 60)s"
    }

    // MARK: CPU and cores

    private static func drawCPU(
        _ buffer: inout CellBuffer, _ state: AppState, _ snapshot: Snapshot?, _ options: RenderOptions, y: Int
    ) {
        buffer.write("CPU", x: 0, y: y, style: Style(bold: true))
        guard let snapshot else { buffer.write("collecting…", x: 5, y: y); return }
        guard let cpu = snapshot.cpu.value else {
            buffer.write("\(unavailable) \(reasonText(snapshot.cpu.unavailableReason))", x: 5, y: y)
            return
        }
        let percentText = String(format: "%5.1f%%", cpu.aggregatePercent)
        drawMeter(
            &buffer, y: y, fraction: cpu.aggregatePercent / 100, valueText: percentText,
            history: state.cpuHistory, options: options)
    }

    private static func drawCores(_ buffer: inout CellBuffer, _ snapshot: Snapshot?, _ options: RenderOptions, y: Int) {
        buffer.write("Core", x: 0, y: y, style: Style(bold: true))
        guard let snapshot else { return }
        var x = 5
        if let cpu = snapshot.cpu.value {
            for percent in cpu.perCorePercent {
                guard x < buffer.columns else { break }
                let style = options.style(foreground: options.loadForeground(percent / 100))
                x += buffer.write(String(options.level(forPercent: percent)), x: x, y: y, style: style)
            }
            x += 2
        } else {
            x += buffer.write(unavailable, x: x, y: y) + 2
        }
        buffer.write(topologyText(snapshot.topology), x: x, y: y, style: Style(dim: true))
    }

    /// Counts are reported as the OS gives them; per-core bars carry no class label.
    static func topologyText(_ topology: Availability<CoreTopology>) -> String {
        guard let topology = topology.value else { return "unclassified cores" }
        var parts = ["unclassified"]
        if let logical = topology.logicalCPUs { parts.append("\(logical) logical") }
        for level in topology.levels {
            let name = level.name.map(TextSanitizer.sanitize) ?? "level \(level.index)"
            parts.append("\(name) \(level.logicalCPUs)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Memory

    private static func drawMemory(
        _ buffer: inout CellBuffer, _ state: AppState, _ snapshot: Snapshot?, _ options: RenderOptions, y: Int
    ) {
        buffer.write("Mem", x: 0, y: y, style: Style(bold: true))
        guard let snapshot else { return }
        guard let memory = snapshot.memory.value else {
            buffer.write("\(unavailable) \(reasonText(snapshot.memory.unavailableReason))", x: 5, y: y)
            return
        }
        guard let used = MemoryMath.approximateUsedBytes(memory) else {
            buffer.write("\(unavailable) approx. used unavailable", x: 5, y: y)
            return
        }
        guard let total = snapshot.physicalMemoryBytes.value,
              let fraction = MemoryMath.fraction(used, of: total)
        else {
            buffer.write("\(ByteFormat.short(used)) approx. used", x: 5, y: y)
            return
        }
        let text = "\(ByteFormat.short(used))/\(ByteFormat.short(total)) approx. used"
        drawMeter(
            &buffer, y: y, fraction: fraction, valueText: text,
            history: state.memoryHistory, options: options)
    }

    private static func drawCategories(_ buffer: inout CellBuffer, _ snapshot: Snapshot?, y: Int) {
        guard let memory = snapshot?.memory.value else { return }
        let items: [(String, UInt64?)] = [
            ("active", memory.activePages), ("inactive", memory.inactivePages), ("wired", memory.wiredPages),
            ("compressor", memory.compressorPages), ("free", memory.freePages),
        ]
        buffer.write(categoryText(items, pageSize: memory.pageSizeBytes), x: 5, y: y)
    }

    private static func drawPurgeableEtc(_ buffer: inout CellBuffer, _ snapshot: Snapshot?, y: Int) {
        guard let memory = snapshot?.memory.value else { return }
        let items: [(String, UInt64?)] = [
            ("purgeable", memory.purgeablePages), ("speculative", memory.speculativePages),
            ("file-backed", memory.fileBackedPages),
        ]
        buffer.write(categoryText(items, pageSize: memory.pageSizeBytes), x: 5, y: y)
    }

    private static func categoryText(_ items: [(String, UInt64?)], pageSize: UInt64) -> String {
        items.map { name, pages in
            let bytes = MemoryMath.bytes(pages: pages, pageSize: pageSize)
            return "\(name) " + (bytes.map(ByteFormat.short) ?? unavailable)
        }.joined(separator: "  ")
    }

    private static func drawSwapAndPressure(
        _ buffer: inout CellBuffer, _ snapshot: Snapshot?, _ options: RenderOptions, y: Int
    ) {
        buffer.write("Swap", x: 0, y: y, style: Style(bold: true))
        guard let snapshot else { return }
        var x = 5
        if let swap = snapshot.swap.value {
            x += buffer.write("\(ByteFormat.short(swap.usedBytes))/\(ByteFormat.short(swap.totalBytes))", x: x, y: y)
        } else {
            x += buffer.write(unavailable, x: x, y: y)
        }
        x += 2
        x += buffer.write("pressure", x: x, y: y, style: Style(dim: true)) + 1

        let (text, foreground) = pressureText(snapshot, theme: options.theme)
        buffer.write(text, x: x, y: y, style: options.style(foreground: foreground))
    }

    /// `unknown` until the OS has delivered a notification; afterwards the last
    /// reported state with its age. Never inferred from free memory.
    static func pressureText(_ snapshot: Snapshot, theme: Theme = .dark) -> (String, UInt8?) {
        let reading = snapshot.pressure
        let name: String
        var foreground: UInt8?
        switch reading.state {
        case .unknown: return ("unknown (no notification yet)", nil)
        case .normal: name = "normal"
        case .warning: name = "warning"; foreground = theme.warning
        case .critical: name = "critical"; foreground = theme.critical
        }
        guard let observed = reading.observedAtNanoseconds, snapshot.capturedAtNanoseconds >= observed else {
            return (name, foreground)
        }
        let age = Double(snapshot.capturedAtNanoseconds - observed) / 1e9
        return ("\(name) (last notified \(durationText(age)) ago)", foreground)
    }

    // MARK: Meters

    /// `LABEL  [bar] value  sparkline`, starting at column 5. The bar takes the
    /// middle of the row; the sparkline takes what is left, newest at the right.
    private static func drawMeter(
        _ buffer: inout CellBuffer, y: Int, fraction: Double, valueText: String,
        history: HistoryBuffer<Double>, options: RenderOptions
    ) {
        let start = 5
        let valueWidth = DisplayWidth.of(valueText)
        let available = buffer.columns - start - 2 - 1 - valueWidth // brackets and a space
        guard available >= 4 else {
            buffer.write(valueText, x: start, y: y)
            return
        }
        let sparkReserve = min(history.capacity, buffer.columns >= ProcessTableLayout.wideColumns ? 60 : 24)
        let barWidth = max(4, min(40, (available - 2) / 2))
        let sparkWidth = max(0, min(sparkReserve, available - barWidth - 2))

        let filled = Int((min(max(fraction, 0), 1) * Double(barWidth)).rounded())
        var x = start
        x += buffer.write("[", x: x, y: y)
        let fillStyle = options.style(foreground: options.loadForeground(fraction))
        x += buffer.write(String(repeating: options.barFilled, count: filled), x: x, y: y, style: fillStyle)
        x += buffer.write(String(repeating: options.barEmpty, count: barWidth - filled), x: x, y: y, style: Style(dim: true))
        x += buffer.write("] ", x: x, y: y)
        x += buffer.write(valueText, x: x, y: y)

        guard sparkWidth > 0 else { return }
        x += 2
        drawSparkline(&buffer, history.recent(sparkWidth), x: x, width: min(sparkWidth, buffer.columns - x), y: y, options: options)
    }

    /// Newest sample at the right edge of `width`; unavailable samples show as gaps.
    private static func drawSparkline(
        _ buffer: inout CellBuffer, _ samples: [HistorySample<Double>], x: Int, width: Int, y: Int,
        options: RenderOptions
    ) {
        guard width > 0 else { return }
        let shown = samples.suffix(width)
        var cursor = x + width - shown.count
        for sample in shown {
            let glyph = sample.value.value.map { options.level(forPercent: $0) } ?? options.gap
            cursor += buffer.write(String(glyph), x: cursor, y: y, style: Style(dim: sample.value.value == nil))
        }
    }

    static func reasonText(_ reason: UnavailableReason?) -> String {
        switch reason {
        case .permissionDenied: "permission denied"
        case .processExited: "process exited"
        case .unsupported: "unsupported"
        case .notYetSampled: "not yet sampled"
        case .malformed: "malformed result"
        case .collectionFailed: "collection failed"
        case nil: "unavailable"
        }
    }
}

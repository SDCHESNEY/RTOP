import Foundation
import MonitorCore

/// Pure rendering: `(state, size) -> CellBuffer`. No I/O, no clock, no OS calls.
public enum ProcessTableView {
    /// Shown for any value that could not be collected (never a zero).
    static let unavailableGlyph = "—"
    static let minimumColumns = 20
    static let minimumRows = 5
    private static let minimumNameWidth = 8

    enum Column: CaseIterable {
        case pid, ppid, name, user, cpu, memory, state

        var title: String {
            switch self {
            case .pid: "PID"
            case .ppid: "PPID"
            case .name: "NAME"
            case .user: "USER"
            case .cpu: "CPU%"
            case .memory: "MEM"
            case .state: "STATE"
            }
        }

        /// Fixed width; `name` is flexible and gets the remainder.
        var width: Int {
            switch self {
            case .pid: 7
            case .ppid: 7
            case .name: 0
            case .user: 10
            case .cpu: 6
            case .memory: 7
            case .state: 8
            }
        }

        var rightAligned: Bool { self == .pid || self == .ppid || self == .cpu || self == .memory }

        var sortKey: SortKey? {
            switch self {
            case .pid: .pid
            case .ppid: nil
            case .name: .name
            case .user: .user
            case .cpu: .cpu
            case .memory: .memory
            case .state: .state
            }
        }
    }

    /// Dropped from the end first when the terminal is narrow.
    private static let dropOrder: [Column] = [.pid, .name, .cpu, .memory, .state, .user]

    static func visibleColumns(width: Int) -> [Column] {
        var chosen: [Column] = [.pid, .name]
        func required(_ cols: [Column]) -> Int {
            let fixed = cols.reduce(0) { $0 + $1.width }
            return fixed + (cols.count - 1) + minimumNameWidth
        }
        if width < required([.pid, .name]) { return [.name] }
        for column in dropOrder.dropFirst(2) {
            guard required(chosen + [column]) <= width else { break }
            chosen.append(column)
        }
        // The extra column only appears on wide terminals, after everything else fits.
        if width >= ProcessTableLayout.wideColumns, chosen.count == dropOrder.count,
           required(chosen + [.ppid]) <= width {
            chosen.append(.ppid)
        }
        return Column.allCases.filter(chosen.contains) // display order
    }

    public static func render(_ state: AppState, size: TerminalSize, options: RenderOptions = RenderOptions()) -> CellBuffer {
        var buffer = CellBuffer(columns: size.columns, rows: size.rows)
        guard size.columns > 0, size.rows > 0 else { return buffer }

        guard size.columns >= minimumColumns, size.rows >= minimumRows else {
            buffer.write("Resize", x: 0, y: 0, style: Style(bold: true))
            if size.rows > 1 { buffer.write("terminal", x: 0, y: 1) }
            return buffer
        }

        OverviewView.draw(&buffer, state, options)
        let columns = visibleColumns(width: size.columns)
        if state.detailPane != nil {
            DetailsView.draw(&buffer, state, options)
        } else {
            drawHeader(&buffer, state, columns: columns, y: ProcessTableLayout.overviewRows(for: size), options: options)
            drawBody(&buffer, state, columns: columns, options: options)
        }
        drawFooter(&buffer, state)
        // Overlays last, highest precedence on top (see KeyBindings.precedence).
        if state.showHelp { Overlay.drawHelp(&buffer, options) }
        if let workflow = state.signalWorkflow { Overlay.drawSignalDialog(&buffer, workflow, options) }
        return buffer
    }

    // MARK: Footer

    private static func drawFooter(_ buffer: inout CellBuffer, _ state: AppState) {
        let y = buffer.rows - 1
        let style = Style(dim: true)
        buffer.fillRow(y, style: style)

        var text: String
        if let editor = state.filterEditor {
            text = "/" + TextSanitizer.sanitize(editor.text) + "_"
            if let error = editor.error { text += "   ! " + error }
            else { text += "   " + KeyBindings.footer(for: .filterEditor) }
        } else if state.signalWorkflow != nil {
            text = KeyBindings.footer(for: .signalModal)
        } else if state.showHelp {
            text = KeyBindings.footer(for: .help)
        } else if let message = state.messages.last {
            let prefix = switch message.kind {
            case .refreshFailed: "refresh failed: "
            case .configWarning: "config: "
            case .signalResult: ""
            }
            text = prefix + TextSanitizer.sanitize(message.text)
        } else if state.detailPane != nil {
            text = KeyBindings.footer(for: .details)
        } else {
            text = KeyBindings.footer(for: .main)
            if !state.filterText.isEmpty { text = "filter: " + TextSanitizer.sanitize(state.filterText) + "  " + text }
            let limited = (state.snapshot?.warnings ?? []).reduce(0) { $0 + $1.count }
            if limited > 0 { text += "  · \(limited) limited" }
        }
        buffer.write(text, x: 0, y: y, style: style)
    }

    // MARK: Table

    private static func columnWidths(_ columns: [Column], total: Int) -> [Column: Int] {
        let fixed = columns.filter { $0 != .name }.reduce(0) { $0 + $1.width }
        let gaps = columns.count - 1
        var widths = Dictionary(uniqueKeysWithValues: columns.map { ($0, $0.width) })
        if columns.contains(.name) { widths[.name] = max(1, total - fixed - gaps) }
        return widths
    }

    private static func cellText(_ text: String, column: Column, width: Int) -> String {
        let clipped = DisplayWidth.truncate(text, toColumns: width, ellipsis: true)
        let pad = String(repeating: " ", count: max(0, width - DisplayWidth.of(clipped)))
        return column.rightAligned ? pad + clipped : clipped + pad
    }

    private static func drawHeader(
        _ buffer: inout CellBuffer, _ state: AppState, columns: [Column], y: Int, options: RenderOptions
    ) {
        let style = Style(bold: true, underline: true)
        buffer.fillRow(y, style: style)
        let widths = columnWidths(columns, total: buffer.columns)
        var x = 0
        for column in columns {
            let w = widths[column] ?? 0
            var title = column == .cpu && state.normalizeCPU ? "NCPU%" : column.title
            if column.sortKey == state.sortKey {
                title += state.sortDescending ? options.descending : options.ascending
            }
            buffer.write(cellText(title, column: column, width: w), x: x, y: y, style: style)
            x += w + 1
        }
    }

    private static func drawBody(
        _ buffer: inout CellBuffer, _ state: AppState, columns: [Column], options: RenderOptions
    ) {
        let size = TerminalSize(columns: buffer.columns, rows: buffer.rows)
        let firstRow = ProcessTableLayout.overviewRows(for: size) + ProcessTableLayout.headerRows
        let visible = ProcessTableLayout.visibleRows(for: size)

        if state.snapshot == nil {
            buffer.write("Collecting…", x: 0, y: firstRow)
            return
        }
        if state.rows.isEmpty {
            buffer.write(state.filter.isEmpty ? "No processes." : "No matching processes.", x: 0, y: firstRow)
            return
        }

        let widths = columnWidths(columns, total: buffer.columns)
        let start = min(max(state.scrollOffset, 0), state.rows.count)
        let end = min(state.rows.count, start + visible)

        for (offset, row) in state.rows[start..<end].enumerated() {
            let y = firstRow + offset
            let selected = row.identity == state.selection
            let style = Style(dim: state.contextRows.contains(row.identity), inverse: selected)
            let depth = state.treeMode && start + offset < state.rowDepths.count ? state.rowDepths[start + offset] : 0
            buffer.fillRow(y, style: style)
            var x = 0
            for column in columns {
                let w = widths[column] ?? 0
                var content = text(for: column, row: row, state: state)
                if column == .name, depth > 0 { content = treeIndent(depth: depth, options: options) + content }
                buffer.write(cellText(content, column: column, width: w), x: x, y: y, style: style)
                x += w + 1
            }
        }
    }

    /// Two columns per level (capped), then a branch glyph. Depth beyond the cap
    /// is not shown; the layout still lists every process once.
    private static func treeIndent(depth: Int, options: RenderOptions) -> String {
        String(repeating: " ", count: min(depth - 1, 12) * 2) + (options.asciiGlyphs ? "`- " : "└ ")
    }

    /// All OS-derived strings pass through the sanitizer here.
    private static func text(for column: Column, row: ProcessSummary, state: AppState) -> String {
        switch column {
        case .pid: return String(row.identity.pid)
        case .ppid: return row.parentPID.value.map { String($0) } ?? unavailableGlyph
        case .name: return TextSanitizer.sanitize(row.name)
        case .user: return row.userName.value.map(TextSanitizer.sanitize) ?? unavailableGlyph
        case .cpu: return state.displayedCPUPercent(row).map { String(format: "%.1f", $0) } ?? unavailableGlyph
        case .memory: return row.residentBytes.value.map(ByteFormat.short) ?? unavailableGlyph
        case .state:
            switch row.status {
            case .running: return "running"
            case .sleeping: return "sleeping"
            case .idle: return "idle"
            case .stopped: return "stopped"
            case .zombie: return "zombie"
            case .unknown: return "?"
            }
        }
    }
}

enum ByteFormat {
    /// Compact binary-unit size, e.g. "512K", "12.3M", "1.5G".
    static func short(_ bytes: UInt64) -> String {
        let kib = 1024.0
        let value = Double(bytes)
        if value < kib { return "\(bytes)B" }
        if value < kib * kib { return String(format: "%.0fK", value / kib) }
        if value < kib * kib * kib { return String(format: "%.1fM", value / (kib * kib)) }
        if value < kib * kib * kib * kib { return String(format: "%.1fG", value / (kib * kib * kib)) }
        return String(format: "%.1fT", value / (kib * kib * kib * kib))
    }
}

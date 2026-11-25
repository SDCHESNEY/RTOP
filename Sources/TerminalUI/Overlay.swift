import MonitorCore

/// Centered boxes drawn over the finished screen: the signal dialog and help. Pure.
enum Overlay {
    struct Line {
        var text: String
        var style: Style = .plain
    }

    private static func drawBox(
        _ buffer: inout CellBuffer, title: String, lines: [Line], options: RenderOptions, preferredWidth: Int
    ) {
        guard buffer.columns >= 6, buffer.rows >= 3 else { return }
        let width = min(buffer.columns - 2, preferredWidth)
        let height = min(buffer.rows - 2, lines.count + 2)
        let x0 = (buffer.columns - width) / 2
        let y0 = (buffer.rows - height) / 2
        let ascii = options.asciiGlyphs
        let h = ascii ? "-" : "─", v = ascii ? "|" : "│"
        let corners = ascii ? ["+", "+", "+", "+"] : ["┌", "┐", "└", "┘"]
        let inner = width - 2

        let titleText = DisplayWidth.truncate(" " + title + " ", toColumns: max(0, inner))
        let top = corners[0] + titleText + String(repeating: h, count: max(0, inner - DisplayWidth.of(titleText))) + corners[1]
        buffer.write(top, x: x0, y: y0, style: Style(bold: true))
        for row in 1..<(height - 1) {
            let y = y0 + row
            buffer.write(v + String(repeating: " ", count: inner) + v, x: x0, y: y)
            let line = lines[row - 1]
            buffer.write(
                DisplayWidth.truncate(TextSanitizer.sanitize(line.text), toColumns: inner - 2, ellipsis: true),
                x: x0 + 2, y: y, style: line.style, maxColumns: inner - 2)
        }
        buffer.write(corners[2] + String(repeating: h, count: inner) + corners[3], x: x0, y: y0 + height - 1, style: Style(bold: true))
    }

    static func drawHelp(_ buffer: inout CellBuffer, _ options: RenderOptions) {
        let lines = KeyBindings.helpLines().map { text in
            Line(text: text, style: text.hasPrefix(" ") || text.isEmpty ? .plain : Style(bold: true))
        }
        drawBox(&buffer, title: "Help", lines: lines, options: options, preferredWidth: 72)
    }

    static func drawSignalDialog(_ buffer: inout CellBuffer, _ workflow: SignalWorkflow, _ options: RenderOptions) {
        let request = workflow.request
        var lines = [Line]()
        lines.append(Line(text: "\(request.name)  (pid \(request.identity.pid))", style: Style(bold: true)))
        var owner = request.uid.map { "uid \($0)" } ?? "owner unknown"
        if let path = request.path { owner += "  " + path }
        lines.append(Line(text: owner, style: Style(dim: true)))
        lines.append(Line(text: ""))

        // The signal chooser: the selected entry is bracketed, never color-only.
        let chooser = ControlSignal.allCases.map { $0 == request.signal ? "[\($0.name)]" : " \($0.name) " }
        lines.append(Line(text: chooser.joined(separator: " "), style: Style(bold: true)))
        lines.append(Line(text: request.signal.explanation, style: request.signal.isDestructive ? Style(bold: true) : .plain))
        lines.append(Line(text: ""))

        switch workflow.stage {
        case .confirm:
            if request.isProtected {
                lines.append(Line(text: "Protected target: root-owned or a system location.", style: Style(bold: true)))
                lines.append(Line(text: "Enter or y continues to a second confirmation."))
            } else {
                lines.append(Line(text: "Enter or y sends \(request.signal.name).  n or Esc cancels."))
            }
        case .confirmProtected:
            lines.append(Line(text: "PROTECTED: really send \(request.signal.name) to \(request.name)?", style: Style(bold: true)))
            lines.append(Line(text: "Press y again to send. Enter does not confirm. n or Esc cancels."))
        case .sending:
            lines.append(Line(text: "Sending…"))
        }
        if let notice = workflow.notice { lines.append(Line(text: notice, style: Style(bold: true))) }
        drawBox(&buffer, title: "Send signal", lines: lines, options: options, preferredWidth: 76)
    }
}

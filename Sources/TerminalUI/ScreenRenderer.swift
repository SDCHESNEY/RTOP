/// Turns successive `CellBuffer`s into minimal terminal output.
///
/// The renderer remembers the last frame it produced and emits only the
/// changed spans of each row. It does no I/O: the caller writes the returned
/// string in one batch and calls `invalidate()` if the write failed.
public struct ScreenRenderer {
    private var previous: CellBuffer?
    private let truecolor: Bool

    /// `truecolor` emits palette colors as 24-bit sequences.
    public init(truecolor: Bool = false) { self.truecolor = truecolor }

    /// Forces the next frame to repaint everything (after resize or a failed write).
    public mutating func invalidate() { previous = nil }

    public mutating func frame(for buffer: CellBuffer) -> String {
        defer { previous = buffer }
        var out = ""
        var current = Style.plain
        out += "\u{1B}[0m"

        let reference: CellBuffer?
        if let previous, previous.columns == buffer.columns, previous.rows == buffer.rows {
            reference = previous
        } else {
            out += "\u{1B}[2J"
            reference = nil
        }

        for y in 0..<buffer.rows {
            guard let (first, last) = changedSpan(row: y, in: buffer, against: reference) else { continue }
            out += "\u{1B}[\(y + 1);\(first + 1)H"
            for x in first...last {
                let cell = buffer[x, y]
                guard let glyph = cell.glyph else { continue } // right half of a wide character
                if cell.style != current {
                    out += cell.style.escapeSequence(truecolor: truecolor)
                    current = cell.style
                }
                out.append(glyph)
            }
        }
        if current != .plain { out += "\u{1B}[0m" }
        return out
    }

    private func changedSpan(row y: Int, in buffer: CellBuffer, against old: CellBuffer?) -> (Int, Int)? {
        guard buffer.columns > 0 else { return nil }
        guard let old else {
            // Full repaint: skip trailing default blanks (the screen was just cleared).
            var last = buffer.columns - 1
            while last >= 0, buffer[last, y] == .blank { last -= 1 }
            return last >= 0 ? (0, last) : nil
        }
        var first = 0
        while first < buffer.columns, buffer[first, y] == old[first, y] { first += 1 }
        guard first < buffer.columns else { return nil }
        var last = buffer.columns - 1
        while last > first, buffer[last, y] == old[last, y] { last -= 1 }

        // Never start in the middle of a wide character, or end before its right half.
        if buffer[first, y].glyph == nil, first > 0 { first -= 1 }
        if last + 1 < buffer.columns, buffer[last + 1, y].glyph == nil { last += 1 }
        return (first, last)
    }
}

/// Text attributes. Colors are 256-palette indexes; nil is the terminal default.
public struct Style: Sendable, Equatable {
    public var bold = false
    public var dim = false
    public var underline = false
    public var inverse = false
    public var foreground: UInt8?
    public var background: UInt8?

    public init(
        bold: Bool = false, dim: Bool = false, underline: Bool = false, inverse: Bool = false,
        foreground: UInt8? = nil, background: UInt8? = nil
    ) {
        self.bold = bold
        self.dim = dim
        self.underline = underline
        self.inverse = inverse
        self.foreground = foreground
        self.background = background
    }

    public static let plain = Style()

    /// SGR sequence that sets exactly this style from a reset state.
    var escapeSequence: String {
        var codes = ["0"]
        if bold { codes.append("1") }
        if dim { codes.append("2") }
        if underline { codes.append("4") }
        if inverse { codes.append("7") }
        if let foreground { codes.append("38;5;\(foreground)") }
        if let background { codes.append("48;5;\(background)") }
        return "\u{1B}[" + codes.joined(separator: ";") + "m"
    }
}

public struct Cell: Sendable, Equatable {
    /// `nil` marks the right half of a double-width character.
    public var glyph: Character?
    public var style: Style

    public static let blank = Cell(glyph: " ", style: .plain)
}

/// A grid of cells. Wide characters occupy a lead cell plus a continuation
/// cell, and the buffer never leaves half of one behind.
public struct CellBuffer: Sendable, Equatable {
    public let columns: Int
    public let rows: Int
    public private(set) var cells: [Cell]

    public init(columns: Int, rows: Int) {
        self.columns = max(0, columns)
        self.rows = max(0, rows)
        self.cells = Array(repeating: .blank, count: self.columns * self.rows)
    }

    public subscript(x: Int, y: Int) -> Cell {
        cells[y * columns + x]
    }

    /// Writes `text` starting at (x, y), clipped to `maxColumns` (default: the
    /// right edge). Returns the number of columns consumed. A wide character
    /// that does not fit is dropped rather than split.
    @discardableResult
    public mutating func write(_ text: String, x: Int, y: Int, style: Style = .plain, maxColumns: Int? = nil) -> Int {
        guard y >= 0, y < rows, x < columns else { return 0 }
        let limit = min(columns, x + (maxColumns ?? columns))
        var cursor = max(x, 0)
        for ch in text {
            let w = DisplayWidth.of(ch)
            if cursor + w > limit { break }
            if cursor < 0 { continue }
            set(Cell(glyph: ch, style: style), x: cursor, y: y)
            if w == 2 { set(Cell(glyph: nil, style: style), x: cursor + 1, y: y) }
            cursor += w
        }
        return cursor - max(x, 0)
    }

    /// Fills a row (or the part of it from `x`) with styled blanks.
    public mutating func fillRow(_ y: Int, style: Style, from x: Int = 0) {
        guard y >= 0, y < rows else { return }
        for col in max(x, 0)..<columns {
            set(Cell(glyph: " ", style: style), x: col, y: y)
        }
    }

    private mutating func set(_ cell: Cell, x: Int, y: Int) {
        let i = y * columns + x
        if cells[i].glyph == nil {
            // Overwriting a right half blanks its lead.
            if x > 0 { cells[i - 1] = .blank }
        } else if let old = cells[i].glyph, x + 1 < columns, cells[i + 1].glyph == nil, DisplayWidth.of(old) == 2 {
            // Overwriting a lead blanks its right half.
            cells[i + 1] = .blank
        }
        cells[i] = cell
    }

    /// Plain text of one row (continuation cells skipped), for tests and debugging.
    public func rowText(_ y: Int) -> String {
        guard y >= 0, y < rows else { return "" }
        var out = ""
        for x in 0..<columns {
            if let g = self[x, y].glyph { out.append(g) }
        }
        return out
    }
}

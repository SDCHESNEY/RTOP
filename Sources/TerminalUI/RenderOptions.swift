public enum ColorMode: Sendable, Equatable {
    /// Attributes only (bold, dim, inverse): safe on any terminal.
    case mono
    /// Adds 256-palette foreground colors to bars and status text.
    case palette256
}

/// How the pure view draws. The defaults (mono, Unicode) need nothing from the terminal.
public struct RenderOptions: Sendable, Equatable {
    public var color: ColorMode
    /// Replaces block, sparkline, and arrow glyphs with ASCII.
    public var asciiGlyphs: Bool

    public init(color: ColorMode = .mono, asciiGlyphs: Bool = false) {
        self.color = color
        self.asciiGlyphs = asciiGlyphs
    }

    // MARK: Glyphs

    var barFilled: String { asciiGlyphs ? "#" : "█" }
    var barEmpty: String { asciiGlyphs ? "-" : "░" }
    var gap: Character { asciiGlyphs ? "?" : "·" }
    var ascending: String { asciiGlyphs ? "^" : "▲" }
    var descending: String { asciiGlyphs ? "v" : "▼" }
    private var levels: [Character] {
        asciiGlyphs ? Array(" .:-=+*#") : Array("▁▂▃▄▅▆▇█")
    }

    /// One glyph for a 0...100 value.
    func level(forPercent value: Double) -> Character {
        let clamped = min(max(value, 0), 100)
        return levels[min(levels.count - 1, Int(clamped / 100 * Double(levels.count)))]
    }

    // MARK: Colors

    func style(foreground: UInt8?, bold: Bool = false, dim: Bool = false) -> Style {
        Style(bold: bold, dim: dim, foreground: color == .palette256 ? foreground : nil)
    }

    /// Green / yellow / red by load.
    func loadForeground(_ fraction: Double) -> UInt8 {
        fraction < 0.6 ? 34 : (fraction < 0.85 ? 178 : 160)
    }
}

extension RenderOptions {
    /// Conservative detection from environment hints only (no terminal queries):
    /// a non-empty `NO_COLOR`, or a missing/`dumb` `TERM`, means mono; a non-UTF-8
    /// locale means ASCII glyphs. Phase 4 adds `--color` / `--theme` overrides.
    public static func detect(environment: [String: String]) -> RenderOptions {
        var options = RenderOptions()
        let term = environment["TERM"] ?? ""
        let noColor = !(environment["NO_COLOR"] ?? "").isEmpty
        options.color = (noColor || term.isEmpty || term == "dumb") ? .mono : .palette256

        let locale = ["LC_ALL", "LC_CTYPE", "LANG"].lazy.compactMap { environment[$0] }.first { !$0.isEmpty } ?? ""
        let utf8 = locale.lowercased().contains("utf-8") || locale.lowercased().contains("utf8")
        options.asciiGlyphs = !utf8
        return options
    }
}

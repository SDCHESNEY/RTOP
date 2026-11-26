import MonitorCore

public enum ColorMode: Sendable, Equatable {
    /// Attributes only (bold, dim, inverse): safe on any terminal.
    case mono
    /// Adds 256-palette foreground colors to bars and status text.
    case palette256
    /// The same palette colors, emitted as 24-bit sequences.
    case truecolor
}

/// How the pure view draws. The defaults (mono, Unicode) need nothing from the terminal.
public struct RenderOptions: Sendable, Equatable {
    public var color: ColorMode
    /// Replaces block, sparkline, and arrow glyphs with ASCII.
    public var asciiGlyphs: Bool
    public var theme: Theme

    public init(color: ColorMode = .mono, asciiGlyphs: Bool = false, theme: Theme = .dark) {
        self.color = color
        self.asciiGlyphs = asciiGlyphs
        self.theme = theme
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
        Style(bold: bold, dim: dim, foreground: color == .mono ? nil : foreground)
    }

    func loadForeground(_ fraction: Double) -> UInt8 { theme.loadForeground(fraction) }
}

extension RenderOptions {
    /// Conservative detection from environment hints only (no terminal queries):
    /// a non-empty `NO_COLOR`, or a missing/`dumb` `TERM`, means mono; a non-UTF-8
    /// locale means ASCII glyphs.
    public static func detect(environment: [String: String]) -> RenderOptions {
        detect(environment: environment, theme: .dark, color: .auto)
    }

    /// Applies the user's `--theme` / `--color` choices on top of the hints.
    /// A non-empty `NO_COLOR` always wins; the mono theme and `--color never` mean no color;
    /// `auto` falls back to mono on a missing/`dumb` `TERM`; `256` and `truecolor` are explicit
    /// requests and are honored regardless of `TERM`.
    public static func detect(environment: [String: String], theme: ThemeName, color: ColorSetting) -> RenderOptions {
        var options = RenderOptions(theme: Theme.named(theme))
        let term = environment["TERM"] ?? ""
        let noColor = !(environment["NO_COLOR"] ?? "").isEmpty

        if noColor || theme == .mono || color == .never {
            options.color = .mono
        } else {
            switch color {
            case .auto: options.color = (term.isEmpty || term == "dumb") ? .mono : .palette256
            case .palette256: options.color = .palette256
            case .truecolor: options.color = .truecolor
            case .never: options.color = .mono
            }
        }

        let locale = ["LC_ALL", "LC_CTYPE", "LANG"].lazy.compactMap { environment[$0] }.first { !$0.isEmpty } ?? ""
        let utf8 = locale.lowercased().contains("utf-8") || locale.lowercased().contains("utf8")
        options.asciiGlyphs = !utf8
        return options
    }
}

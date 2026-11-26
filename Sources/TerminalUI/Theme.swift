import MonitorCore

/// The semantic colors the views use, as 256-palette indexes. The dark theme
/// keeps the original palette; light uses darker shades that stay legible on a
/// light background. Mono carries no colors at all (attributes only).
public struct Theme: Sendable, Equatable {
    public var name: ThemeName
    /// Low load, "normal" pressure fill.
    public var ok: UInt8
    public var warning: UInt8
    public var critical: UInt8

    public static let dark = Theme(name: .dark, ok: 34, warning: 178, critical: 160)
    public static let light = Theme(name: .light, ok: 22, warning: 130, critical: 88)
    public static let mono = Theme(name: .mono, ok: 0, warning: 0, critical: 0)

    public static func named(_ name: ThemeName) -> Theme {
        switch name {
        case .dark: .dark
        case .light: .light
        case .mono: .mono
        }
    }

    /// Green / yellow / red by load.
    func loadForeground(_ fraction: Double) -> UInt8 {
        fraction < 0.6 ? ok : (fraction < 0.85 ? warning : critical)
    }
}

/// Palette index to RGB for the optional true-color output path, using the
/// standard xterm values: 0–15 system colors, 16–231 a 6×6×6 cube, 232–255 grays.
enum Palette {
    private static let system: [(UInt8, UInt8, UInt8)] = [
        (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0), (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
        (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0), (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
    ]

    static func rgb(_ index: UInt8) -> (UInt8, UInt8, UInt8) {
        switch index {
        case 0..<16:
            return system[Int(index)]
        case 16..<232:
            let n = Int(index) - 16
            func level(_ v: Int) -> UInt8 { v == 0 ? 0 : UInt8(55 + 40 * v) }
            return (level(n / 36), level(n / 6 % 6), level(n % 6))
        default:
            let gray = UInt8(8 + 10 * (Int(index) - 232))
            return (gray, gray, gray)
        }
    }
}

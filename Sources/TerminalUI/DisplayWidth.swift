/// Terminal column widths. This is an approximation of East Asian Width plus
/// zero-width combining marks; emulators differ, especially for ambiguous-width
/// characters, which are treated as one column (see Documentation/Architecture.md).
public enum DisplayWidth {
    public static func of(_ scalar: Unicode.Scalar) -> Int {
        let v = scalar.value
        if v < 0x20 || (0x7F...0x9F).contains(v) { return 0 }
        if v == 0x200B || v == 0x200C || v == 0x200D || v == 0xFEFF { return 0 }
        if (0x1160...0x11FF).contains(v) { return 0 } // Hangul medial vowels / final consonants
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return 0
        default: break
        }
        return isWide(v) ? 2 : 1
    }

    /// Width of one grapheme cluster (at least 1 so every cluster occupies a cell).
    public static func of(_ character: Character) -> Int {
        var width = 0
        for scalar in character.unicodeScalars {
            if scalar.value == 0xFE0F { return 2 } // emoji presentation selector
            width = max(width, of(scalar))
        }
        return max(width, 1)
    }

    public static func of(_ text: String) -> Int {
        text.reduce(0) { $0 + of($1) }
    }

    /// Cuts `text` to at most `columns` columns on a grapheme boundary, never
    /// splitting a wide character. With `ellipsis`, an overlong string ends in "…".
    public static func truncate(_ text: String, toColumns columns: Int, ellipsis: Bool = false) -> String {
        guard columns > 0 else { return "" }
        if of(text) <= columns { return text }
        let budget = ellipsis ? columns - 1 : columns
        var used = 0
        var out = ""
        for ch in text {
            let w = of(ch)
            if used + w > budget { break }
            out.append(ch)
            used += w
        }
        return ellipsis ? out + "…" : out
    }

    private static func isWide(_ v: UInt32) -> Bool {
        switch v {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF,
             0x20000...0x2FFFD, 0x30000...0x3FFFD:
            true
        default:
            false
        }
    }
}

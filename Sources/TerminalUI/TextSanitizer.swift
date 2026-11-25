/// Makes operating-system-derived text safe to place on screen.
///
/// Every control character that a terminal could interpret (C0 including ESC,
/// DEL, C1, line/paragraph separators, and bidirectional overrides) is
/// replaced with a visible placeholder, so process names, paths, and error
/// text can never become terminal control sequences.
public enum TextSanitizer {
    public static let placeholder: Unicode.Scalar = "?"
    /// Bounds the work done for pathological inputs.
    public static let maxScalars = 1024

    public static func sanitize(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for (count, scalar) in text.unicodeScalars.enumerated() {
            if count >= maxScalars { break }
            out.append(isUnsafe(scalar) ? placeholder : scalar)
        }
        return String(out)
    }

    static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: true            // C0, DEL, C1
        case 0x061C, 0x200E, 0x200F: true               // Arabic letter mark, LRM, RLM
        case 0x2028, 0x2029: true                       // line / paragraph separator
        case 0x202A...0x202E, 0x2066...0x2069: true     // bidi embeddings, overrides, isolates
        default: false
        }
    }
}

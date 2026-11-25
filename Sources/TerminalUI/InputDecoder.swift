import Foundation
import MonitorCore

/// Incremental keyboard decoder: UTF-8 text, control bytes, and CSI/SS3
/// escape sequences. Input may arrive split across reads, several events may
/// arrive in one read, and malformed bytes are reported as `.unknown` instead
/// of corrupting later input. All storage is bounded.
public struct InputDecoder: Sendable {
    /// Longest escape-sequence body kept; longer ones are discarded to their final byte.
    public static let maxSequenceLength = 32

    private enum State: Sendable {
        case ground
        case utf8(expected: Int, bytes: [UInt8])
        case escape
        case csi(params: [UInt8])
        case csiOverflow
        case ss3
    }

    private var state = State.ground

    public init() {}

    /// True while a lone ESC byte is held back waiting to learn whether it
    /// starts a longer sequence. The caller flushes it after a short timeout.
    public var hasPendingEscape: Bool {
        if case .escape = state { return true }
        return false
    }

    public mutating func feed(_ bytes: [UInt8]) -> [KeyEvent] {
        var events = [KeyEvent]()
        for byte in bytes { step(byte, into: &events) }
        return events
    }

    /// Resolves a held ESC as the Escape key (called after the ESC timeout).
    public mutating func flushPendingEscape() -> [KeyEvent] {
        guard hasPendingEscape else { return [] }
        state = .ground
        return [.escape]
    }

    private mutating func step(_ byte: UInt8, into events: inout [KeyEvent]) {
        switch state {
        case .ground:
            ground(byte, into: &events)

        case .utf8(let expected, var bytes):
            guard (0x80...0xBF).contains(byte) else {
                // Truncated sequence: report it, then treat this byte afresh.
                events.append(.unknown)
                state = .ground
                ground(byte, into: &events)
                return
            }
            bytes.append(byte)
            if bytes.count < expected {
                state = .utf8(expected: expected, bytes: bytes)
                return
            }
            state = .ground
            if let text = String(bytes: bytes, encoding: .utf8), text.count == 1, let ch = text.first {
                events.append(.character(ch))
            } else {
                events.append(.unknown) // overlong, surrogate, or out of range
            }

        case .escape:
            switch byte {
            case UInt8(ascii: "["): state = .csi(params: [])
            case UInt8(ascii: "O"): state = .ss3
            case 0x1B: events.append(.escape) // ESC ESC: first is a bare Escape, second stays pending
            default:
                // ESC + key (Alt-combination): no action depends on it, so ignore both.
                state = .ground
                events.append(.unknown)
            }

        case .csi(var params):
            switch byte {
            case 0x20...0x3F: // parameter and intermediate bytes
                params.append(byte)
                state = params.count > Self.maxSequenceLength ? .csiOverflow : .csi(params: params)
            case 0x40...0x7E: // final byte
                state = .ground
                events.append(Self.decodeCSI(params: params, final: byte))
            default: // control or 8-bit byte inside a sequence: abandon it
                state = .ground
                events.append(.unknown)
                ground(byte, into: &events)
            }

        case .csiOverflow:
            if (0x40...0x7E).contains(byte) {
                state = .ground
                events.append(.unknown)
            }

        case .ss3:
            state = .ground
            switch byte {
            case UInt8(ascii: "A"): events.append(.up)
            case UInt8(ascii: "B"): events.append(.down)
            case UInt8(ascii: "C"): events.append(.right)
            case UInt8(ascii: "D"): events.append(.left)
            case UInt8(ascii: "H"): events.append(.home)
            case UInt8(ascii: "F"): events.append(.end)
            default: events.append(.unknown)
            }
        }
    }

    private mutating func ground(_ byte: UInt8, into events: inout [KeyEvent]) {
        switch byte {
        case 0x1B: state = .escape
        case 0x0D, 0x0A: events.append(.enter)
        case 0x09: events.append(.tab)
        case 0x08, 0x7F: events.append(.backspace)
        case 0x01...0x1A: events.append(.ctrl(Character(Unicode.Scalar(byte + 0x60))))
        case 0x20...0x7E: events.append(.character(Character(Unicode.Scalar(byte))))
        case 0xC2...0xDF: state = .utf8(expected: 2, bytes: [byte])
        case 0xE0...0xEF: state = .utf8(expected: 3, bytes: [byte])
        case 0xF0...0xF4: state = .utf8(expected: 4, bytes: [byte])
        default: events.append(.unknown) // NUL, 0x1C-0x1F, stray continuation, invalid lead
        }
    }

    private static func decodeCSI(params: [UInt8], final: UInt8) -> KeyEvent {
        // Only the first numeric parameter matters; modifiers (e.g. "1;5A") are ignored.
        let first = params.prefix { (0x30...0x39).contains($0) }
        let number = first.isEmpty ? nil : Int(String(decoding: first, as: UTF8.self))
        switch final {
        case UInt8(ascii: "A"): return .up
        case UInt8(ascii: "B"): return .down
        case UInt8(ascii: "C"): return .right
        case UInt8(ascii: "D"): return .left
        case UInt8(ascii: "H"): return .home
        case UInt8(ascii: "F"): return .end
        case UInt8(ascii: "~"):
            switch number {
            case 1, 7: return .home
            case 4, 8: return .end
            case 3: return .delete
            case 5: return .pageUp
            case 6: return .pageDown
            default: return .unknown
            }
        default: return .unknown
        }
    }
}

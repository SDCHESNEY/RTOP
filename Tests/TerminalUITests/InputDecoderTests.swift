import MonitorCore
import Testing
@testable import TerminalUI

@Suite struct InputDecoderTests {
    private func decode(_ bytes: [UInt8]) -> [KeyEvent] {
        var d = InputDecoder()
        return d.feed(bytes)
    }

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    @Test(arguments: [
        ("\u{1B}[A", KeyEvent.up), ("\u{1B}[B", .down), ("\u{1B}[C", .right), ("\u{1B}[D", .left),
        ("\u{1B}OA", .up), ("\u{1B}OB", .down), ("\u{1B}OH", .home), ("\u{1B}OF", .end),
        ("\u{1B}[H", .home), ("\u{1B}[F", .end),
        ("\u{1B}[1~", .home), ("\u{1B}[4~", .end), ("\u{1B}[7~", .home), ("\u{1B}[8~", .end),
        ("\u{1B}[3~", .delete), ("\u{1B}[5~", .pageUp), ("\u{1B}[6~", .pageDown),
        ("\u{1B}[1;5A", .up), ("\u{1B}[1;2B", .down), // modifiers ignored, direction kept
        ("q", .character("q")), ("j", .character("j")), ("é", .character("é")), ("日", .character("日")),
        ("😀", .character("😀")),
        ("\r", .enter), ("\n", .enter), ("\t", .tab), ("\u{7F}", .backspace), ("\u{08}", .backspace),
        ("\u{03}", .ctrl("c")), ("\u{04}", .ctrl("d")), ("\u{1A}", .ctrl("z")),
        ("\u{1B}[99~", .unknown), ("\u{1B}[Z", .unknown), ("\u{1B}OZ", .unknown),
    ])
    func decodesKnownSequences(input: String, expected: KeyEvent) {
        #expect(decode(bytes(input)) == [expected])
    }

    @Test func multipleEventsInOneRead() {
        #expect(decode(bytes("jk\u{1B}[B\u{1B}[Aq")) == [.character("j"), .character("k"), .down, .up, .character("q")])
    }

    @Test func sequenceSplitAtEveryByteBoundary() {
        let input = bytes("a\u{1B}[1;5Bé\u{1B}[6~😀")
        let whole = decode(input)
        for cut in 0...input.count {
            var d = InputDecoder()
            let events = d.feed(Array(input[..<cut])) + d.feed(Array(input[cut...]))
            #expect(events == whole, "split at \(cut)")
        }
    }

    @Test func byteAtATime() {
        var d = InputDecoder()
        var events = [KeyEvent]()
        for b in bytes("\u{1B}[A日x") { events += d.feed([b]) }
        #expect(events == [.up, .character("日"), .character("x")])
    }

    @Test func lonelyEscapeWaitsThenFlushesAsEscape() {
        var d = InputDecoder()
        #expect(d.feed([0x1B]) == [])
        #expect(d.hasPendingEscape)
        #expect(d.flushPendingEscape() == [.escape])
        #expect(!d.hasPendingEscape)
        #expect(d.flushPendingEscape() == []) // nothing pending any more
    }

    @Test func escapeFollowedByContinuationIsNotAnEscapeKey() {
        var d = InputDecoder()
        #expect(d.feed([0x1B]) == [])
        #expect(d.feed(bytes("[A")) == [.up])
        #expect(!d.hasPendingEscape)
    }

    @Test func doubleEscapeEmitsOneEscapeAndKeepsOnePending() {
        var d = InputDecoder()
        #expect(d.feed([0x1B, 0x1B]) == [.escape])
        #expect(d.hasPendingEscape)
    }

    @Test func altKeyIsIgnoredNotMisreadAsACommand() {
        #expect(decode(bytes("\u{1B}q")) == [.unknown]) // must not quit
    }

    @Test func invalidBytesAreReportedAndDecodingRecovers() {
        #expect(decode([0x80, UInt8(ascii: "a")]) == [.unknown, .character("a")]) // stray continuation
        #expect(decode([0xFF, UInt8(ascii: "a")]) == [.unknown, .character("a")]) // invalid lead
        #expect(decode([0xC0, 0xAF]) == [.unknown, .unknown]) // overlong lead rejected outright
        #expect(decode([0xE0, 0x80, 0x80]) == [.unknown]) // overlong 3-byte form
        #expect(decode([0xED, 0xA0, 0x80]) == [.unknown]) // UTF-16 surrogate
        #expect(decode([0xF4, 0x90, 0x80, 0x80]) == [.unknown]) // above U+10FFFF
    }

    @Test func truncatedUTF8IsFollowedByNormalDecoding() {
        #expect(decode([0xE6, 0x97, UInt8(ascii: "q")]) == [.unknown, .character("q")])
        #expect(decode([0xE6, 0x97, 0x1B, UInt8(ascii: "["), UInt8(ascii: "A")]) == [.unknown, .up])
    }

    @Test func overlongEscapeSequenceIsDiscardedWithBoundedStorage() {
        var input: [UInt8] = [0x1B, UInt8(ascii: "[")]
        input += [UInt8](repeating: UInt8(ascii: "1"), count: 10_000)
        input += [UInt8(ascii: "A"), UInt8(ascii: "q")]
        #expect(decode(input) == [.unknown, .character("q")])
    }

    @Test func controlByteInsideSequenceAbandonsIt() {
        #expect(decode([0x1B, UInt8(ascii: "["), UInt8(ascii: "1"), 0x03]) == [.unknown, .ctrl("c")])
    }

    @Test func nulAndOtherUnboundControlsAreUnknown() {
        #expect(decode([0x00, 0x1C]) == [.unknown, .unknown])
    }

    /// Fixed-seed fuzz: any byte stream decodes without trapping, the decoder
    /// ends in a sane state, and a fresh `q` after a flush still works.
    @Test func seededFuzzNeverTrapsAndRecovers() {
        var rng = SplitMix64(seed: 0xC0FFEE)
        for _ in 0..<2_000 {
            var d = InputDecoder()
            let length = Int(rng.next() % 200)
            let chunk = (0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            _ = d.feed(chunk)
            _ = d.flushPendingEscape()
            // Terminate whatever was in progress with bytes that end every state.
            _ = d.feed([UInt8(ascii: "A"), 0x0D])
            #expect(d.feed([UInt8(ascii: "q")]).last == .character("q"))
        }
    }
}

/// Small deterministic generator so fuzz failures reproduce.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

import Foundation
import MonitorCore
import Testing
@testable import TerminalUI

@Suite struct Phase4ViewTests {
    private let size = TerminalSize(columns: 120, rows: 40)
    private func render(_ state: AppState, _ options: RenderOptions = RenderOptions()) -> CellBuffer {
        ProcessTableView.render(state, size: state.terminalSize, options: options)
    }

    // MARK: Color resolution

    private let utf8 = ["TERM": "xterm-256color", "LANG": "en_US.UTF-8"]

    @Test func noColorWinsOverEveryExplicitChoice() {
        let env = utf8.merging(["NO_COLOR": "1"]) { $1 }
        for color in ColorSetting.allCases {
            #expect(RenderOptions.detect(environment: env, theme: .dark, color: color).color == .mono)
        }
        #expect(RenderOptions.detect(environment: utf8.merging(["NO_COLOR": ""]) { $1 }, theme: .dark, color: .palette256).color == .palette256)
    }

    @Test func monoThemeAndNeverMeanNoColor() {
        #expect(RenderOptions.detect(environment: utf8, theme: .mono, color: .palette256).color == .mono)
        #expect(RenderOptions.detect(environment: utf8, theme: .dark, color: .never).color == .mono)
    }

    @Test func autoUsesEnvironmentHintsButExplicitModesAreHonored() {
        #expect(RenderOptions.detect(environment: utf8, theme: .dark, color: .auto).color == .palette256)
        #expect(RenderOptions.detect(environment: ["TERM": "dumb"], theme: .dark, color: .auto).color == .mono)
        #expect(RenderOptions.detect(environment: [:], theme: .dark, color: .auto).color == .mono)
        #expect(RenderOptions.detect(environment: ["TERM": "dumb"], theme: .dark, color: .palette256).color == .palette256)
        #expect(RenderOptions.detect(environment: utf8, theme: .light, color: .truecolor).color == .truecolor)
    }

    @Test func themeSelectsThePalette() {
        #expect(RenderOptions.detect(environment: utf8, theme: .light, color: .auto).theme == .light)
        #expect(RenderOptions.detect(environment: utf8, theme: .dark, color: .auto).theme == .dark)
    }

    @Test func themesDifferOnlyInColorNeverInText() {
        var state = ViewFixtures.state(size: size)
        state.cpuHistory.append(HistorySample(atNanoseconds: 1, value: .value(90)))
        let dark = render(state, RenderOptions(color: .palette256, theme: .dark))
        let light = render(state, RenderOptions(color: .palette256, theme: .light))
        let mono = render(state, RenderOptions(color: .mono, theme: .mono))
        for y in 0..<size.rows {
            #expect(dark.rowText(y) == light.rowText(y))
            #expect(dark.rowText(y) == mono.rowText(y))
        }
        #expect(dark != light)
        // Mono carries no colors at all.
        for y in 0..<size.rows { for x in 0..<size.columns {
            #expect(mono[x, y].style.foreground == nil && mono[x, y].style.background == nil)
        } }
    }

    @Test func lightThemeUsesItsOwnLoadColors() {
        var state = ViewFixtures.state(size: size)
        _ = Reducer.reduce(&state, .snapshot(ViewFixtures.snapshot(
            sequence: 2, cpu: .value(CPUReading(aggregatePercent: 95, perCorePercent: [95])))))
        let light = render(state, RenderOptions(color: .palette256, theme: .light))
        let foregrounds = Set((0..<size.columns).compactMap { light[$0, 1].style.foreground })
        #expect(foregrounds.contains(Theme.light.critical))
        #expect(!foregrounds.contains(Theme.dark.critical))
    }

    // MARK: True color

    @Test func truecolorEmitsRGBForPaletteIndexes() {
        var buffer = CellBuffer(columns: 4, rows: 1)
        buffer.write("ab", x: 0, y: 0, style: Style(foreground: 196)) // cube: 255,0,0
        var truecolor = ScreenRenderer(truecolor: true)
        var palette = ScreenRenderer()
        #expect(truecolor.frame(for: buffer).contains("38;2;255;0;0"))
        #expect(!truecolor.frame(for: buffer).contains("38;5;"))
        #expect(palette.frame(for: buffer).contains("38;5;196"))
    }

    @Test func paletteConversionMatchesXtermAnchors() {
        #expect(Palette.rgb(16) == (0, 0, 0))
        #expect(Palette.rgb(21) == (0, 0, 255))
        #expect(Palette.rgb(231) == (255, 255, 255))
        #expect(Palette.rgb(232) == (8, 8, 8))
        #expect(Palette.rgb(255) == (238, 238, 238))
        #expect(Palette.rgb(1) == (205, 0, 0))
        // Every index converts without trapping.
        for i in 0...255 { _ = Palette.rgb(UInt8(i)) }
    }

    // MARK: Normalized CPU

    @Test func normalizedModeRelabelsAndScalesTheColumn() {
        var state = ViewFixtures.state(size: size) // 12 logical CPUs; Xcode row has 145.67
        let plain = render(state)
        #expect((0..<size.rows).contains { plain.rowText($0).contains("CPU%") && plain.rowText($0).contains("PID") })
        #expect((0..<size.rows).contains { plain.rowText($0).contains("145.7") })

        state.normalizeCPU = true
        let normalized = render(state)
        #expect((0..<size.rows).contains { normalized.rowText($0).contains("NCPU%") })
        #expect((0..<size.rows).contains { normalized.rowText($0).contains("12.1") }) // 145.67 / 12
        #expect(!(0..<size.rows).contains { normalized.rowText($0).contains("145.7") })
    }

    @Test func configWarningIsShownInTheFooterWithItsPrefix() {
        var state = ViewFixtures.state(size: size)
        state.messages.append(StatusMessage(kind: .configWarning, text: "ignored unknown key \"x\"\u{1B}[2J"))
        let buffer = render(state)
        let footer = buffer.rowText(size.rows - 1)
        #expect(footer.hasPrefix("config: ignored unknown key"))
        #expect(!footer.contains("\u{1B}"))
    }

    // MARK: Hostile metadata

    private static let hostileNames = [
        "evil\u{1B}[2J\u{1B}[31mname", "line1\nline2\rline3", "bidi\u{202E}txet\u{2066}x\u{2069}", "\u{9B}31mcsi",
        String(repeating: "N", count: 50_000), "tab\there", "nul\u{0}byte", "日本語\u{200F}שלום", "\u{1B}]0;title\u{07}",
        String(decoding: [0xFF, 0xFE, 0x41, 0xC0, 0xAF], as: UTF8.self), // invalid UTF-8, decoded lossily
    ]

    @Test func hostileProcessMetadataNeverReachesTheTerminalAsControlSequences() {
        let rows = Self.hostileNames.enumerated().map { index, name in
            ViewFixtures.row(Int32(100 + index), name, user: name, cpu: 1, rss: 1024)
        }
        var state = ViewFixtures.state(size: size, rows: rows)
        _ = Reducer.reduce(&state, .key(.character("d")))
        for options in [RenderOptions(), RenderOptions(color: .truecolor, asciiGlyphs: true)] {
            for pane in [false, true] {
                var s = state
                if !pane { _ = Reducer.reduce(&s, .key(.escape)) }
                var renderer = ScreenRenderer(truecolor: options.color == .truecolor)
                let frame = renderer.frame(for: render(s, options))
                // The only escape sequences in a frame are the renderer's own: CSI cursor moves, SGR, and clear.
                var scalars = frame.unicodeScalars.makeIterator()
                while let scalar = scalars.next() {
                    if scalar == "\u{1B}" {
                        let next = scalars.next()
                        #expect(next == "[", "non-CSI escape in frame")
                    } else {
                        #expect(scalar.value >= 0x20 && scalar.value != 0x7F && !(0x80...0x9F).contains(scalar.value),
                                "control scalar \(scalar.value) in frame")
                        #expect(!(0x202A...0x202E).contains(scalar.value) && !(0x2066...0x2069).contains(scalar.value))
                    }
                }
                #expect(!frame.contains("\u{1B}[2J\u{1B}[31m")) // the hostile payload itself is not intact
            }
        }
    }

    // MARK: Performance (WP4.6)

    @Test func fiveThousandProcessRenderStaysWithinBudget() {
        let rows = (0..<5000).map { i in
            ViewFixtures.row(Int32(i + 2), "process-\(i)", cpu: Double(i % 300) / 3, rss: UInt64(i) * 4096)
        }
        var state = ViewFixtures.state(size: size, rows: rows)
        var renderer = ScreenRenderer()
        // Warm up, then measure the pure render + diff (what each refresh costs after reduction).
        for _ in 0..<5 { _ = renderer.frame(for: render(state)) }
        var samples = [Double]()
        for i in 0..<50 {
            if i % 10 == 0 { _ = Reducer.reduce(&state, .key(.down)) }
            let start = ContinuousClock.now
            _ = renderer.frame(for: render(state))
            let d = ContinuousClock.now - start
            samples.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        }
        samples.sort()
        let median = samples[samples.count / 2]
        let worst = samples.last ?? 0
        print("render 5000 processes @120x40: median \(median) ms, worst \(worst) ms")
        // Documentation/Performance.md records the measured numbers; the target is ~16 ms.
        // The bound here is generous so a loaded CI machine does not flake, yet still catches an
        // accidental O(n) per-cell regression.
        #expect(median < 50, "median render \(median) ms")
    }
}

import Foundation
import Testing
@testable import MonitorCore

@Suite struct ConfigurationTests {
    private func parse(_ json: String) -> Result<ConfigFile.Parsed, ConfigFile.Failure> {
        ConfigFile.parse(Data(json.utf8))
    }

    // MARK: Precedence

    @Test func defaultsApplyWhenNothingIsSet() {
        #expect(Settings.resolve(cli: PartialSettings(), file: PartialSettings()) == Settings())
    }

    @Test func fileOverridesDefaultsAndCLIOverridesFile() {
        var file = PartialSettings()
        file.refreshMilliseconds = 2000
        file.sortKey = .cpu
        file.theme = .light
        file.descending = true
        var cli = PartialSettings()
        cli.refreshMilliseconds = 500
        cli.theme = .mono

        let s = Settings.resolve(cli: cli, file: file)
        #expect(s.refreshMilliseconds == 500)  // CLI beats file
        #expect(s.sortKey == .cpu)             // file beats default
        #expect(s.theme == .mono)
        #expect(s.descending == true)
        #expect(s.historySamples == 60)        // default
    }

    @Test func explicitFalseOnTheCLIBeatsTrueInTheFile() {
        // "supplied" and "absent" differ: --no-mouse supplies false.
        var file = PartialSettings()
        file.mouse = true
        file.normalizeCPU = true
        var cli = PartialSettings()
        cli.mouse = false
        let s = Settings.resolve(cli: cli, file: file)
        #expect(s.mouse == false)
        #expect(s.normalizeCPU == true)
    }

    // MARK: File parsing

    @Test func sampleFileParsesToEveryKey() throws {
        let parsed = try parse(ConfigFile.sample).get()
        #expect(parsed.unknownKeys.isEmpty)
        #expect(parsed.settings.refreshMilliseconds == 1000)
        #expect(parsed.settings.sortKey == .cpu)
        #expect(parsed.settings.descending == true)
        #expect(parsed.settings.theme == .dark)
        #expect(parsed.settings.color == .auto)
        #expect(parsed.settings.normalizeCPU == false)
        #expect(parsed.settings.historySamples == 60)
        #expect(parsed.settings.mouse == false)
    }

    @Test func sampleKeysAreExactlyTheKnownKeys() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(ConfigFile.sample.utf8)) as? [String: Any])
        #expect(Set(object.keys) == Set(ConfigFile.knownKeys))
    }

    @Test func emptyObjectIsValidAndSetsNothing() throws {
        #expect(try parse("{}").get().settings == PartialSettings())
    }

    @Test func unknownKeysAreReportedSortedAndOtherKeysStillApply() throws {
        let parsed = try parse(#"{"refreshMS": 500, "theme": "light", "zzz": 1}"#).get()
        #expect(parsed.unknownKeys == ["refreshMS", "zzz"])
        #expect(parsed.settings.theme == .light)
        #expect(parsed.settings.refreshMilliseconds == nil)
    }

    @Test(arguments: ["", "{", "not json", "{\"a\":}", "[1,2]", "\"text\"", "42", "null"])
    func malformedOrWrongShapeIsRejected(json: String) {
        guard case .failure = parse(json) else {
            Issue.record("expected rejection of \(json)")
            return
        }
    }

    @Test(arguments: [
        #"{"refreshMs": 249}"#, #"{"refreshMs": 0}"#, #"{"refreshMs": -1}"#, #"{"refreshMs": 1.5}"#,
        #"{"refreshMs": "500"}"#, #"{"refreshMs": true}"#, #"{"refreshMs": 1e30}"#,
        #"{"refreshMs": 99999999999999999999}"#, #"{"refreshMs": null}"#,
        #"{"historySamples": 0}"#, #"{"historySamples": 3601}"#, #"{"historySamples": 2.5}"#,
        #"{"sort": "state"}"#, #"{"sort": 3}"#, #"{"theme": "blue"}"#, #"{"theme": null}"#,
        #"{"color": 256}"#, #"{"color": "16"}"#,
        #"{"descending": "yes"}"#, #"{"descending": 1}"#, #"{"normalizeCpu": 0}"#, #"{"mouse": "false"}"#,
    ])
    func wrongTypesAndOutOfRangeValuesInvalidateTheFile(json: String) {
        guard case .failure(.invalidValue) = parse(json) else {
            Issue.record("expected invalidValue for \(json)")
            return
        }
    }

    @Test func boundsAreInclusive() throws {
        #expect(try parse(#"{"refreshMs": 250}"#).get().settings.refreshMilliseconds == 250)
        #expect(try parse(#"{"historySamples": 1}"#).get().settings.historySamples == 1)
        #expect(try parse(#"{"historySamples": 3600}"#).get().settings.historySamples == 3600)
        #expect(try parse(#"{"color": "256"}"#).get().settings.color == .palette256)
    }

    @Test func oversizedFileIsRejectedWithoutParsing() {
        let big = Data(repeating: 0x20, count: ConfigFile.maximumBytes + 1)
        #expect(ConfigFile.parse(big) == .failure(.tooLarge))
    }

    // MARK: Loader

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rtop-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func missingDefaultFileIsNormal() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let loaded = try ConfigLoader.load(explicitPath: nil, defaultURL: dir.appendingPathComponent("config.json"))
        #expect(loaded == LoadedConfiguration())
    }

    @Test func invalidDefaultFileWarnsAndYieldsDefaults() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try Data(#"{"refreshMs": 5}"#.utf8).write(to: url)
        let loaded = try ConfigLoader.load(explicitPath: nil, defaultURL: url)
        #expect(loaded.settings == PartialSettings())
        #expect(loaded.warnings.count == 1)
        #expect(loaded.warnings[0].contains("refreshMs"))
        #expect(loaded.warnings[0].contains("using defaults"))
    }

    @Test func validDefaultFileWithUnknownKeyWarnsActionably() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try Data(#"{"theme": "light", "refresh": 5}"#.utf8).write(to: url)
        let loaded = try ConfigLoader.load(explicitPath: nil, defaultURL: url)
        #expect(loaded.settings.theme == .light)
        #expect(loaded.warnings.count == 1)
        #expect(loaded.warnings[0].contains("\"refresh\""))
        #expect(loaded.warnings[0].contains("refreshMs")) // lists the known keys
    }

    @Test func explicitMissingFileIsAnError() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: ConfigError.self) {
            try ConfigLoader.load(explicitPath: dir.appendingPathComponent("nope.json").path, defaultURL: dir.appendingPathComponent("d.json"))
        }
    }

    @Test func explicitInvalidFileIsAnErrorEvenIfDefaultIsFine() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let explicit = dir.appendingPathComponent("x.json")
        try Data("{".utf8).write(to: explicit)
        #expect(throws: ConfigError.self) {
            try ConfigLoader.load(explicitPath: explicit.path, defaultURL: dir.appendingPathComponent("d.json"))
        }
    }

    @Test func explicitValidFileLoads() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let explicit = dir.appendingPathComponent("x.json")
        try Data(ConfigFile.sample.utf8).write(to: explicit)
        let loaded = try ConfigLoader.load(explicitPath: explicit.path, defaultURL: dir.appendingPathComponent("d.json"))
        #expect(loaded.settings.sortKey == .cpu)
        #expect(loaded.warnings.isEmpty)
    }

    @Test func directoryAndOversizedFilesAreRejected() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: ConfigError.self) { try ConfigLoader.load(explicitPath: dir.path, defaultURL: dir) }
        let big = dir.appendingPathComponent("big.json")
        try Data(repeating: 0x20, count: ConfigFile.maximumBytes + 1).write(to: big)
        #expect(throws: ConfigError.self) { try ConfigLoader.load(explicitPath: big.path, defaultURL: dir) }
    }

    @Test func defaultURLIsUnderApplicationSupport() {
        let url = ConfigLoader.defaultURL(home: URL(fileURLWithPath: "/Users/x"))
        #expect(url.path == "/Users/x/Library/Application Support/rtop/config.json")
    }

    // MARK: Normalized CPU

    private func snapshot(_ sequence: UInt64, _ processes: [ProcessSummary], logicalCPUs: Int?) -> Snapshot {
        Snapshot(
            sequence: sequence, processes: processes,
            topology: logicalCPUs.map { .value(CoreTopology(logicalCPUs: $0, physicalCPUs: nil)) } ?? .unavailable(.unsupported))
    }

    @Test func normalizedCPUDividesByLogicalCPUsAndNeverInventsAValue() {
        var state = AppState(terminalSize: TerminalSize(columns: 80, rows: 24))
        let process = Fixtures.process(5, cpu: 200)
        state.snapshot = snapshot(1, [process], logicalCPUs: 8)
        #expect(state.displayedCPUPercent(process) == 200)
        state.normalizeCPU = true
        #expect(state.displayedCPUPercent(process) == 25)

        state.snapshot = snapshot(2, [process], logicalCPUs: nil)
        #expect(state.displayedCPUPercent(process) == nil) // unknown divisor → unavailable, not unscaled

        let unsampled = Fixtures.process(6, cpu: nil)
        state.snapshot = snapshot(3, [unsampled], logicalCPUs: 8)
        #expect(state.displayedCPUPercent(unsampled) == nil)
    }

    @Test func configWarningClearsOnTheNextKey() {
        var state = AppState(terminalSize: TerminalSize(columns: 80, rows: 24))
        state.messages.append(StatusMessage(kind: .configWarning, text: "x"))
        _ = Reducer.reduce(&state, .key(.down))
        #expect(state.messages.isEmpty)
    }

    // MARK: Generated documentation

    @Test func completionsMentionEveryVisibleOptionForEveryShell() throws {
        for shell in ["zsh", "bash", "fish"] {
            let script = try #require(OptionDocs.completions(shell: shell))
            for spec in Options.specs where !spec.hidden {
                let needle = shell == "fish" ? String(spec.name.dropFirst(2)) : spec.name
                #expect(script.contains(needle), "\(shell) completions miss \(spec.name)")
            }
            #expect(!script.contains("spike"))
        }
        #expect(OptionDocs.completions(shell: "tcsh") == nil)
    }

    @Test func completionsOfferTheChoices() throws {
        let zsh = try #require(OptionDocs.completions(shell: "zsh"))
        #expect(zsh.contains("(pid name user cpu memory status)"))
        #expect(zsh.contains("(auto never 256 truecolor)"))
    }

    @Test func manPageDocumentsEveryVisibleOption() {
        let page = OptionDocs.manPage(version: "9.9", date: "2026-01-02")
        #expect(page.contains(".TH RTOP 1"))
        #expect(page.contains("9.9"))
        #expect(page.contains("2026-01-02"))
        for spec in Options.specs where !spec.hidden { #expect(page.contains(spec.name)) }
        #expect(page.contains("NO_COLOR"))
    }
}

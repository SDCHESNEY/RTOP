import Testing
@testable import MonitorCore

@Suite struct OptionsTests {
    private func parse(_ args: String...) -> Result<Options.Command, Options.ParseError> { Options.parse(args) }

    private func request(_ args: String...) -> Options.RunRequest? {
        guard case .success(.run(let request)) = Options.parse(args) else { return nil }
        return request
    }

    @Test func absentOptionsStayAbsent() {
        #expect(request() == Options.RunRequest())
        #expect(request()?.settings.refreshMilliseconds == nil)
    }

    @Test func refreshAcceptsSeparateAndInlineValues() {
        #expect(request("--refresh-ms", "500")?.settings.refreshMilliseconds == 500)
        #expect(request("--refresh-ms=250")?.settings.refreshMilliseconds == 250)
    }

    @Test func everyOptionParsesIntoItsField() throws {
        let r = try #require(request(
            "--sort", "memory", "--descending", "--theme=light", "--color", "256", "--normalize-cpu",
            "--history-samples", "120", "--config", "/tmp/x.json", "--no-mouse"))
        #expect(r.settings.sortKey == .memory)
        #expect(r.settings.descending == true)
        #expect(r.settings.theme == .light)
        #expect(r.settings.color == .palette256)
        #expect(r.settings.normalizeCPU == true)
        #expect(r.settings.historySamples == 120)
        #expect(r.settings.mouse == false)
        #expect(r.configPath == "/tmp/x.json")
    }

    @Test func statusIsTheSpellingForTheStateSortKey() {
        #expect(request("--sort", "status")?.settings.sortKey == .state)
        #expect(request("--sort", "state") == nil)
    }

    @Test(arguments: [
        ["--sort", "bogus"], ["--theme", "blue"], ["--color", "16"], ["--color", ""],
        ["--history-samples", "0"], ["--history-samples", "3601"], ["--history-samples", "-1"],
        ["--history-samples", "99999999999999999999"], ["--config", ""], ["--descending=yes"],
        ["--generate-completions", "powershell"],
    ])
    func invalidValuesAreRejected(args: [String]) {
        guard case .failure = Options.parse(args) else {
            Issue.record("expected rejection of \(args)")
            return
        }
    }

    @Test func historyBoundsAreInclusive() {
        #expect(request("--history-samples", "1")?.settings.historySamples == 1)
        #expect(request("--history-samples", "3600")?.settings.historySamples == 3600)
    }

    @Test func generatorsAreCommands() {
        #expect(parse("--generate-completions", "zsh") == .success(.generateCompletions(shell: "zsh")))
        #expect(parse("--generate-man") == .success(.generateMan))
    }

    @Test(arguments: ["249", "0", "-5", "abc", "", "1.5", "1e3", " 500", "+500"])
    func refreshRejectsMalformedOrTooSmall(value: String) {
        guard case .failure(.invalidValue) = Options.parse(["--refresh-ms", value]) else {
            Issue.record("expected rejection of '\(value)'")
            return
        }
    }

    @Test func refreshRejectsOverflow() {
        guard case .failure(.invalidValue(_, _, let reason)) = parse("--refresh-ms", "99999999999999999999999") else {
            Issue.record("expected overflow rejection")
            return
        }
        #expect(reason.contains("too large"))
    }

    @Test func missingValueAndUnknownOptions() {
        #expect(parse("--refresh-ms") == .failure(.missingValue("--refresh-ms")))
        #expect(parse("--bogus") == .failure(.unknownOption("--bogus")))
        #expect(parse("stray") == .failure(.unexpectedArgument("stray")))
    }

    @Test func helpAndVersionNeverNeedATerminal() {
        #expect(parse("--help") == .success(.help))
        #expect(parse("-h") == .success(.help))
        #expect(parse("--version") == .success(.version))
        #expect(parse("--version", "--help") == .success(.help))
    }

    @Test func usageIsGeneratedFromTheTableAndHidesSpikes() {
        let usage = Options.usage()
        #expect(usage.contains("--refresh-ms <N>"))
        for spec in Options.specs where !spec.hidden { #expect(usage.contains(spec.name)) }
        #expect(usage.contains("Exit status"))
        #expect(usage.contains("--help"))
        #expect(!usage.contains("--spike"))
    }
}

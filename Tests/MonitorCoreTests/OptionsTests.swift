import Testing
@testable import MonitorCore

@Suite struct OptionsTests {
    private func parse(_ args: String...) -> Result<Options.Command, Options.ParseError> { Options.parse(args) }

    @Test func defaultsToRunWithDefaultInterval() {
        #expect(parse() == .success(.run(refreshMilliseconds: 1000)))
    }

    @Test func refreshAcceptsSeparateAndInlineValues() {
        #expect(parse("--refresh-ms", "500") == .success(.run(refreshMilliseconds: 500)))
        #expect(parse("--refresh-ms=250") == .success(.run(refreshMilliseconds: 250)))
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
        #expect(usage.contains("--help"))
        #expect(!usage.contains("--spike"))
    }
}

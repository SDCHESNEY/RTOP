import Testing
@testable import MonitorCore

@Suite struct ProcessFilterTests {
    private func filter(_ text: String) -> ProcessFilter {
        guard case .success(let f) = ProcessFilter.parse(text) else {
            Issue.record("expected \(text) to parse")
            return .empty
        }
        return f
    }

    private func names(_ f: ProcessFilter, _ rows: [ProcessSummary]) -> [String] { f.apply(to: rows).map(\.name) }

    private let rows = [
        Fixtures.process(1, name: "launchd", user: "root", uid: 0, path: "/sbin/launchd"),
        Fixtures.process(412, name: "Safari", user: "shawn", uid: 501, path: "/Applications/Safari.app/Contents/MacOS/Safari"),
        Fixtures.process(413, name: "Safari Helper", user: "shawn", uid: 501, path: "/Applications/Safari.app/Helper"),
        Fixtures.process(900, name: "日本語アプリ", user: nil, uid: 502),
        Fixtures.process(901, name: "Élan", user: "other", uid: 503),
    ]

    @Test func emptyAndWhitespaceOnlyTextIsTheEmptyFilter() {
        #expect(filter("").isEmpty)
        #expect(filter("   \t ").isEmpty)
        #expect(filter("").apply(to: rows) == rows)
    }

    @Test func plainTermsMatchNameCaseInsensitively() {
        #expect(names(filter("safari"), rows) == ["Safari", "Safari Helper"])
        #expect(names(filter("SAFARI"), rows) == ["Safari", "Safari Helper"])
        #expect(names(filter("launch"), rows) == ["launchd"])
    }

    @Test func plainTermsDoNotMatchPathTextOrUsers() {
        #expect(names(filter("sbin"), rows).isEmpty)
        #expect(names(filter("shawn"), rows).isEmpty)
    }

    @Test func termsCombineWithAnd() {
        #expect(names(filter("safari helper"), rows) == ["Safari Helper"])
        #expect(names(filter("safari user:root"), rows).isEmpty)
        #expect(names(filter("safari user:shawn pid:413"), rows) == ["Safari Helper"])
    }

    @Test func pidIsExactAndPositive() {
        #expect(names(filter("pid:41"), rows).isEmpty)
        #expect(names(filter("pid:412"), rows) == ["Safari"])
        for bad in ["pid:0", "pid:-5", "pid:abc", "pid:4x", "pid:+4", "pid:99999999999"] {
            guard case .failure(.invalidPID) = ProcessFilter.parse(bad) else {
                Issue.record("\(bad) should be rejected")
                continue
            }
        }
    }

    @Test func userMatchesNameExactlyOrNumericUID() {
        #expect(names(filter("user:root"), rows) == ["launchd"])
        #expect(names(filter("user:ROOT"), rows) == ["launchd"])
        #expect(names(filter("user:sha"), rows).isEmpty) // exact, not prefix
        #expect(names(filter("user:501"), rows) == ["Safari", "Safari Helper"])
        #expect(names(filter("user:0"), rows) == ["launchd"])
        #expect(names(filter("user:502"), rows) == ["日本語アプリ"]) // unavailable name, numeric UID still works
    }

    @Test func pathMatchesAvailablePathOnly() {
        #expect(names(filter("path:/sbin"), rows) == ["launchd"])
        #expect(names(filter("path:safari.app"), rows) == ["Safari", "Safari Helper"])
        var noPath = rows
        noPath[0].executablePath = .unavailable(.permissionDenied)
        #expect(names(filter("path:/sbin"), noPath).isEmpty)
    }

    @Test func predicatePrefixesAreCaseInsensitive() {
        #expect(names(filter("PID:412"), rows) == ["Safari"])
        #expect(names(filter("User:root"), rows) == ["launchd"])
        #expect(names(filter("PATH:/SBIN"), rows) == ["launchd"])
    }

    @Test func unknownPrefixIsAnOrdinaryTextTerm() {
        #expect(filter("foo:bar").terms == [.text("foo:bar")])
        #expect(names(filter("foo:bar"), rows).isEmpty)
    }

    @Test func emptyPredicateValuesAreErrors() {
        #expect(ProcessFilter.parse("pid:") == .failure(.emptyValue(predicate: "pid")))
        #expect(ProcessFilter.parse("safari user:") == .failure(.emptyValue(predicate: "user")))
        #expect(ProcessFilter.parse("path:") == .failure(.emptyValue(predicate: "path")))
        #expect(!ProcessFilter.ParseError.emptyValue(predicate: "user").description.isEmpty)
    }

    @Test func unicodeMatchingIgnoresCase() {
        #expect(names(filter("élan"), rows) == ["Élan"])
        #expect(names(filter("ÉLAN"), rows) == ["Élan"])
        #expect(names(filter("日本"), rows) == ["日本語アプリ"])
    }
}

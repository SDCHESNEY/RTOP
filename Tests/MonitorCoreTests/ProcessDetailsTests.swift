import Foundation
import Testing
@testable import MonitorCore

@Suite struct ProcArgsParserTests {
    /// argc, path, NUL padding, arguments, environment.
    private func buffer(argc: Int32, path: String, padding: Int = 3, args: [String], env: [String] = []) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc) { Array($0) }
        bytes += Array(path.utf8) + [0]
        bytes += [UInt8](repeating: 0, count: padding)
        for a in args { bytes += Array(a.utf8) + [0] }
        for e in env { bytes += Array(e.utf8) + [0] }
        return bytes
    }

    private func parsed(_ bytes: [UInt8]) throws -> ProcArgsParser.Parsed {
        try ProcArgsParser.parse(bytes).get()
    }

    @Test func parsesPathAndArgumentsAndIgnoresEnvironment() throws {
        let p = try parsed(buffer(argc: 3, path: "/bin/sleep", args: ["sleep", "-x", "30"], env: ["SECRET=1", "PATH=/bin"]))
        #expect(p.executablePath == "/bin/sleep")
        #expect(p.commandLine.arguments == ["sleep", "-x", "30"])
        #expect(!p.commandLine.truncated)
        #expect(!p.commandLine.arguments.contains { $0.contains("SECRET") })
    }

    @Test func zeroArguments() throws {
        let p = try parsed(buffer(argc: 0, path: "/x", args: []))
        #expect(p.commandLine.arguments.isEmpty)
        #expect(!p.commandLine.truncated)
    }

    @Test func emptyArgumentsArePreserved() throws {
        let p = try parsed(buffer(argc: 3, path: "/x", args: ["a", "", "b"]))
        #expect(p.commandLine.arguments == ["a", "", "b"])
    }

    @Test func fewerArgumentsThanArgcIsTruncation() throws {
        let p = try parsed(buffer(argc: 5, path: "/x", args: ["a", "b"]))
        #expect(p.commandLine.arguments == ["a", "b"])
        #expect(p.commandLine.truncated)
    }

    @Test func bufferCutMidArgumentKeepsThePrefixAndFlagsTruncation() throws {
        var bytes = buffer(argc: 2, path: "/x", args: ["first", "second"])
        bytes.removeLast(4) // cuts "second\0" to "sec"
        let p = try parsed(bytes)
        #expect(p.commandLine.arguments == ["first", "sec"])
        #expect(p.commandLine.truncated)
    }

    @Test func overlongArgumentIsBoundedAndFlagged() throws {
        let huge = String(repeating: "a", count: ProcArgsParser.maxArgumentBytes + 500)
        let p = try parsed(buffer(argc: 2, path: "/x", args: [huge, "next"]))
        #expect(p.commandLine.arguments.count == 2)
        #expect(p.commandLine.arguments[0].utf8.count == ProcArgsParser.maxArgumentBytes)
        #expect(p.commandLine.arguments[1] == "next")
        #expect(p.commandLine.truncated)
    }

    @Test func invalidArgcAndShortAndUnterminatedInputAreErrors() {
        #expect(ProcArgsParser.parse([]) == .failure(.tooShort))
        #expect(ProcArgsParser.parse([1, 0, 0]) == .failure(.tooShort))
        #expect(ProcArgsParser.parse(buffer(argc: -1, path: "/x", args: [])) == .failure(.invalidArgumentCount(-1)))
        let big = Int32(ProcArgsParser.maxArguments) + 1
        #expect(ProcArgsParser.parse(buffer(argc: big, path: "/x", args: [])) == .failure(.invalidArgumentCount(big)))
        #expect(ProcArgsParser.parse([1, 0, 0, 0, 0x2F, 0x78]) == .failure(.unterminatedPath))
    }

    @Test func invalidUTF8IsReplacedNotRejected() throws {
        var bytes = withUnsafeBytes(of: Int32(1)) { Array($0) } + Array("/x".utf8) + [0, 0]
        bytes += [0x61, 0xFF, 0xFE, 0x62, 0]
        let p = try parsed(bytes)
        #expect(p.commandLine.arguments == ["a\u{FFFD}\u{FFFD}b"])
    }

    @Test func randomBytesNeverTrap() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let n = Int.random(in: 0..<200, using: &rng)
            let bytes = (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
            _ = ProcArgsParser.parse(bytes)
        }
    }
}

@Suite struct DetailCacheTests {
    private func details(_ pid: Int32) -> ProcessDetails {
        .unavailable(Fixtures.identity(pid), .permissionDenied)
    }

    @Test func evictsLeastRecentlyUsedAtCapacity() {
        var cache = DetailCache(capacity: 3)
        for pid in 1...3 { cache.insert(details(Int32(pid))) }
        _ = cache.lookup(Fixtures.identity(1)) // 1 becomes most recent
        cache.insert(details(4))               // evicts 2
        #expect(cache.count == 3)
        #expect(cache.lookup(Fixtures.identity(2)) == nil)
        #expect(cache.lookup(Fixtures.identity(1)) != nil)
        #expect(cache.lookup(Fixtures.identity(4)) != nil)
    }

    @Test func reinsertReplacesWithoutGrowing() {
        var cache = DetailCache(capacity: 2)
        cache.insert(details(1))
        cache.insert(ProcessDetails(identity: Fixtures.identity(1), commandLine: .value(.init(arguments: ["a"]))))
        #expect(cache.count == 1)
        #expect(cache.lookup(Fixtures.identity(1))?.commandLine.value?.arguments == ["a"])
    }

    @Test func differentStartTimeIsADifferentEntry() {
        var cache = DetailCache()
        cache.insert(details(1))
        #expect(cache.lookup(Fixtures.identity(1, start: 999)) == nil)
    }
}

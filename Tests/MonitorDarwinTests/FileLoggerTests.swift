import Darwin
import Foundation
import Testing
@testable import MonitorDarwin

@Suite struct FileLoggerTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rtop-log-\(UUID().uuidString)")
    }

    private func mode(_ url: URL) -> mode_t? {
        var info = stat()
        return stat(url.path, &info) == 0 ? info.st_mode & 0o777 : nil
    }

    private func contents(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    /// Mutable clock shared with the logger's queue.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var now = Date(timeIntervalSince1970: 1_800_000_000)
        func read() -> Date { lock.withLock { now } }
        func advance(_ seconds: TimeInterval) { lock.withLock { now += seconds } }
    }

    @Test func createsOwnerOnlyDirectoryAndFileLazily() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logger = FileLogger(directory: dir)
        logger.flush()
        #expect(!FileManager.default.fileExists(atPath: dir.path)) // nothing created until a line is written

        logger.log(.info, "hello")
        logger.flush()
        #expect(mode(dir) == 0o700)
        #expect(mode(dir.appendingPathComponent("rtop.log")) == 0o600)
        #expect(contents(dir.appendingPathComponent("rtop.log")).contains(" info hello\n"))
    }

    @Test func existingLooseFileIsTightened() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rtop.log")
        try Data().write(to: file)
        chmod(file.path, 0o644)
        let logger = FileLogger(directory: dir)
        logger.log(.info, "x")
        logger.flush()
        #expect(mode(file) == 0o600)
    }

    @Test func existingLooseDirectoryOwnedByUsIsTightened() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        chmod(dir.path, 0o755)
        let logger = FileLogger(directory: dir)
        logger.log(.info, "x")
        logger.flush()
        #expect(mode(dir) == 0o700)
    }

    @Test func messagesCannotForgeLinesOrInjectControls() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logger = FileLogger(directory: dir)
        logger.log(.warning, "a\nfake 2026 error forged\u{1B}[2J\u{202E}b")
        logger.flush()
        let text = contents(dir.appendingPathComponent("rtop.log"))
        #expect(text.split(separator: "\n").count == 1)
        #expect(!text.contains("\u{1B}"))
        #expect(!text.contains("\u{202E}"))
        #expect(text.contains("a?fake"))
    }

    @Test func overlongMessagesAreBounded() {
        let long = String(repeating: "x", count: 10_000)
        #expect(FileLogger.sanitize(long).count == FileLogger.maxMessageScalars)
    }

    @Test func rotatesAtTheSizeCapAndKeepsOnlyTheRetainedCount() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let policy = FileLogger.Policy(maxBytes: 512, retainedFiles: 2, minimumRepeatInterval: 60)
        let logger = FileLogger(directory: dir, policy: policy)
        for i in 0..<200 { logger.log(.info, "line \(i) " + String(repeating: "p", count: 60)) }
        logger.flush()

        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["rtop.log", "rtop.log.1", "rtop.log.2"])
        for name in names {
            let size = try #require(try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? Int)
            #expect(size <= 512, "\(name) is \(size) bytes")
            #expect(mode(dir.appendingPathComponent(name)) == 0o600)
        }
        #expect(contents(dir.appendingPathComponent("rtop.log")).contains("line 199")) // newest is in the active file
    }

    @Test func repeatedKeyedWarningsAreRateLimitedAndCounted() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let logger = FileLogger(directory: dir, clock: { clock.read() })
        for _ in 0..<5 { logger.log(.warning, "sampling failed", rateLimitKey: "k") }
        logger.log(.warning, "other", rateLimitKey: "other") // a different key is independent
        logger.flush() // let the queue read the clock before it moves
        clock.advance(61)
        logger.log(.warning, "sampling failed", rateLimitKey: "k")
        logger.flush()

        let lines = contents(dir.appendingPathComponent("rtop.log")).split(separator: "\n").map(String.init)
        try #require(lines.count == 3 ? true : nil)
        #expect(lines[0].hasSuffix("sampling failed"))
        #expect(lines[1].hasSuffix("other"))
        #expect(lines[2].hasSuffix("sampling failed (4 similar suppressed)"))
    }

    @Test func unkeyedLinesAreNeverSuppressed() {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logger = FileLogger(directory: dir)
        for _ in 0..<5 { logger.log(.info, "same") }
        logger.flush()
        #expect(contents(dir.appendingPathComponent("rtop.log")).split(separator: "\n").count == 5)
    }

    @Test func refusesToWriteThroughASymlinkAndStaysSilent() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("victim")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("rtop.log"), withDestinationURL: target)

        let logger = FileLogger(directory: dir)
        logger.log(.error, "should not land in the victim")
        logger.flush()
        #expect(contents(target) == "keep")
    }

    @Test func anUnwritableLocationDisablesLoggingWithoutCrashing() {
        let logger = FileLogger(directory: URL(fileURLWithPath: "/dev/null/rtop"))
        logger.log(.error, "nowhere")
        logger.flush()
    }
}

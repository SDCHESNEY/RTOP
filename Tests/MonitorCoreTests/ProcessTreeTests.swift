import Foundation
import Testing
@testable import MonitorCore

@Suite struct ProcessTreeTests {
    private func proc(_ pid: Int32, parent: Int32?, start: UInt64 = 100, name: String? = nil) -> ProcessSummary {
        var p = Fixtures.process(pid, start: start, name: name ?? "p\(pid)")
        p.parentPID = parent.map { .value($0) } ?? .unavailable(.permissionDenied)
        return p
    }

    private func layout(_ rows: [ProcessSummary], filter: ProcessFilter = .empty, key: SortKey = .pid,
                        descending: Bool = false) -> [TreeNode] {
        ProcessTree.layout(rows, filter: filter, key: key, descending: descending)
    }

    private func shape(_ nodes: [TreeNode]) -> [String] {
        nodes.map { "\($0.depth):\($0.process.identity.pid)" }
    }

    @Test func buildsHierarchyUnderPIDOne() {
        let nodes = layout([proc(3, parent: 2), proc(2, parent: 1), proc(1, parent: 0), proc(4, parent: 1)])
        #expect(shape(nodes) == ["0:1", "1:2", "2:3", "1:4"])
        #expect(nodes.allSatisfy { !$0.isContext })
    }

    @Test func siblingsFollowTheSortKeyAndDirection() {
        let rows = [proc(1, parent: 0), proc(2, parent: 1), proc(3, parent: 1), proc(4, parent: 1)]
        #expect(shape(layout(rows, descending: true)) == ["0:1", "1:4", "1:3", "1:2"])
    }

    @Test func missingParentGoesUnderUnattachedNotInventedParent() {
        let nodes = layout([proc(1, parent: 0), proc(50, parent: 999), proc(51, parent: 50), proc(60, parent: nil)])
        #expect(shape(nodes) == ["0:1", "0:-1", "1:50", "2:51", "1:60"])
        #expect(nodes[1].process.isSynthetic)
        #expect(nodes[1].process.name == "Unattached")
    }

    @Test func noUnattachedRowWhenEveryoneIsAttached() {
        let nodes = layout([proc(1, parent: 0), proc(2, parent: 1)])
        #expect(!nodes.contains { $0.process.isSynthetic })
    }

    @Test func cyclesAreBrokenAndEveryProcessAppearsOnce() {
        // 10 <-> 11 form a cycle; 12 is a child of 10; 13 is its own parent.
        let rows = [proc(1, parent: 0), proc(10, parent: 11), proc(11, parent: 10), proc(12, parent: 10), proc(13, parent: 13)]
        let nodes = layout(rows)
        let pids = nodes.map(\.process.identity.pid).filter { $0 > 0 }
        #expect(pids.sorted() == [1, 10, 11, 12, 13])
        #expect(Set(pids).count == pids.count)
        #expect(nodes.contains { $0.process.isSynthetic })
    }

    @Test func reusedParentPIDNewerThanChildIsNotAParent() {
        // Child 20 (started at 100) names parent 7, but pid 7 now belongs to a process started at 500.
        let nodes = layout([proc(1, parent: 0), proc(7, parent: 1, start: 500), proc(20, parent: 7, start: 100)])
        #expect(shape(nodes) == ["0:1", "1:7", "0:-1", "1:20"])
    }

    @Test func olderParentIsAccepted() {
        let nodes = layout([proc(1, parent: 0, start: 10), proc(7, parent: 1, start: 50), proc(20, parent: 7, start: 100)])
        #expect(shape(nodes) == ["0:1", "1:7", "2:20"])
    }

    @Test func depthIsBoundedButNothingIsDropped() {
        var rows = [proc(1, parent: 0)]
        for pid in 2...200 { rows.append(proc(Int32(pid), parent: Int32(pid - 1))) }
        let nodes = layout(rows)
        #expect(nodes.count == 200)
        #expect(nodes.map(\.depth).max() == ProcessTree.maxDepth)
    }

    @Test func filterKeepsMatchesAndMarksAncestorsAsContext() throws {
        let rows = [proc(1, parent: 0, name: "launchd"), proc(2, parent: 1, name: "shell"),
                    proc(3, parent: 2, name: "target"), proc(4, parent: 1, name: "other")]
        let filter = try ProcessFilter.parse("target").get()
        let nodes = layout(rows, filter: filter)
        #expect(shape(nodes) == ["0:1", "1:2", "2:3"])
        #expect(nodes.map(\.isContext) == [true, true, false])
    }

    @Test func filterMatchWithNoMatchesYieldsNothing() throws {
        let nodes = layout([proc(1, parent: 0), proc(50, parent: 999)], filter: try ProcessFilter.parse("zzz").get())
        #expect(nodes.isEmpty)
    }

    @Test func unattachedIsContextForMatchingOrphan() throws {
        let nodes = layout([proc(1, parent: 0), proc(50, parent: 999, name: "lost")], filter: try ProcessFilter.parse("lost").get())
        #expect(shape(nodes) == ["0:-1", "1:50"])
        #expect(nodes[0].isContext)
    }

    @Test func setOfProcessesIsPreservedForRandomForests() {
        var rng = SeededGenerator(seed: 42)
        for _ in 0..<50 {
            let n = Int.random(in: 1...60, using: &rng)
            let rows = (1...n).map { pid in
                proc(Int32(pid), parent: Int32.random(in: 0...Int32(n + 5), using: &rng), start: UInt64.random(in: 1...300, using: &rng))
            }
            let nodes = layout(rows, key: .name)
            let pids = nodes.map(\.process.identity.pid).filter { $0 > 0 }
            #expect(pids.sorted() == rows.map(\.identity.pid).sorted())
        }
    }

    @Test func fiveThousandNodesLayOutQuicklyIncludingADeepChain() {
        var rows = [proc(1, parent: 0)]
        for pid in 2...2500 { rows.append(proc(Int32(pid), parent: Int32(pid - 1))) } // deep chain
        for pid in 2501...5000 { rows.append(proc(Int32(pid), parent: Int32.random(in: 1...2500))) }
        let clock = ContinuousClock()
        var nodes = [TreeNode]()
        let elapsed = clock.measure { nodes = layout(rows, key: .name) }
        #expect(nodes.count == 5000)
        #expect(elapsed < .seconds(2)) // generous: a regression guard, not a benchmark
    }
}

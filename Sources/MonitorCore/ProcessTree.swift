/// One display row of the process tree.
public struct TreeNode: Sendable, Equatable {
    public var process: ProcessSummary
    public var depth: Int
    /// Shown only because a descendant matches the filter.
    public var isContext: Bool
}

extension ProcessSummary {
    /// The "Unattached" group row. It is not a process and can never be a target.
    public static let unattachedGroup = ProcessSummary(
        identity: ProcessIdentity(pid: -1, start: nil),
        parentPID: .unavailable(.unsupported), name: "Unattached",
        uid: .unavailable(.unsupported), userName: .unavailable(.unsupported),
        cpuPercent: .unavailable(.unsupported), residentBytes: .unavailable(.unsupported),
        status: .unknown, executablePath: .unavailable(.unsupported))

    public var isSynthetic: Bool { identity.pid < 0 }
}

/// Parent/child layout built from one snapshot. The hierarchy is an imperfect
/// observation, so the rules are defensive:
///
/// - PID 1 (and anything whose parent is the kernel, PPID 0) is a root.
/// - A process whose parent is unknown, absent from the snapshot, itself, or
///   *started after* the child (the PID was reused) goes under a synthetic
///   "Unattached" row rather than under an invented parent.
/// - Cycles are unreachable from any root; their members end up under
///   "Unattached" too, so every process appears exactly once.
/// - Depth is bounded for display; deeper nodes keep the maximum depth.
/// - Traversal is iterative, so a 5,000-deep chain cannot overflow the stack.
public enum ProcessTree {
    public static let maxDepth = 64

    public static func layout(
        _ processes: [ProcessSummary], filter: ProcessFilter, key: SortKey, descending: Bool
    ) -> [TreeNode] {
        let count = processes.count
        var indexByPID = [Int32: Int](minimumCapacity: count)
        for (i, p) in processes.enumerated() where indexByPID[p.identity.pid] == nil { indexByPID[p.identity.pid] = i }

        var children = [[Int]](repeating: [], count: count)
        var roots = [Int]()
        var orphans = [Int]()
        for i in 0..<count {
            switch parent(of: i, in: processes, indexByPID: indexByPID) {
            case .root: roots.append(i)
            case .orphan: orphans.append(i)
            case .parent(let j): children[j].append(i)
            }
        }

        func sorted(_ indices: [Int]) -> [Int] {
            indices.sorted { ProcessSort.precedes(processes[$0], processes[$1], key: key, descending: descending) }
        }
        for i in 0..<count where children[i].count > 1 { children[i] = sorted(children[i]) }

        // Emission order in preorder; `index == nil` is the "Unattached" row.
        var order: [(index: Int?, depth: Int, parentSlot: Int?)] = []
        order.reserveCapacity(count + 1)
        var visited = [Bool](repeating: false, count: count)

        func walk(_ tops: [Int], depth: Int, parentSlot: Int?) {
            var stack: [(index: Int, depth: Int, parentSlot: Int?)] = tops.reversed().map { ($0, depth, parentSlot) }
            while let item = stack.popLast() {
                if visited[item.index] { continue }
                visited[item.index] = true
                order.append((item.index, min(item.depth, maxDepth), item.parentSlot))
                let slot = order.count - 1
                for child in children[item.index].reversed() { stack.append((child, item.depth + 1, slot)) }
            }
        }

        var rootOrder = sorted(roots)
        if let pidOne = rootOrder.firstIndex(where: { processes[$0].identity.pid == 1 }) {
            rootOrder.insert(rootOrder.remove(at: pidOne), at: 0)
        }
        walk(rootOrder, depth: 0, parentSlot: nil)

        // Orphans, then anything a cycle left unreachable, under one synthetic group.
        let groupSlot = order.count
        order.append((nil, 0, nil))
        walk(sorted(orphans), depth: 1, parentSlot: groupSlot)
        walk(sorted((0..<count).filter { !visited[$0] }), depth: 1, parentSlot: groupSlot)
        if order.count == groupSlot + 1 { order.removeLast() }

        // Filter: matches plus their ancestors (parents precede children, so one reverse pass).
        let unfiltered = filter.isEmpty
        var matches = [Bool](repeating: unfiltered, count: order.count)
        if !unfiltered {
            for (slot, entry) in order.enumerated() {
                if let i = entry.index { matches[slot] = filter.matches(processes[i]) }
            }
        }
        var keep = matches
        for slot in stride(from: order.count - 1, through: 0, by: -1) where keep[slot] {
            if let parentSlot = order[slot].parentSlot { keep[parentSlot] = true }
        }

        var nodes = [TreeNode]()
        for (slot, entry) in order.enumerated() where keep[slot] {
            nodes.append(TreeNode(
                process: entry.index.map { processes[$0] } ?? .unattachedGroup,
                depth: entry.depth, isContext: !matches[slot]))
        }
        return nodes
    }

    private enum Parent { case root, orphan, parent(Int) }

    private static func parent(of i: Int, in processes: [ProcessSummary], indexByPID: [Int32: Int]) -> Parent {
        let p = processes[i]
        if p.identity.pid == 1 { return .root }
        guard let ppid = p.parentPID.value else { return .orphan }
        if ppid == 0 { return .root }
        if ppid == p.identity.pid { return .orphan }
        guard let j = indexByPID[ppid] else { return .orphan }
        if let childStart = p.identity.start, let parentStart = processes[j].identity.start, parentStart > childStart {
            return .orphan // PID reuse: the "parent" is newer than the child
        }
        return .parent(j)
    }
}

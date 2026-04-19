import Foundation

/// One drawn rectangle in the flamegraph: position is a [0,1] fraction of the
/// total width so the view can lay out at any size and reflow on zoom.
struct FlamegraphCell: Identifiable, Sendable {
    let id: UUID
    let symbol: String
    let module: String?
    let sampleCount: Int
    let depth: Int
    let xRatio: Double
    let widthRatio: Double

    /// Index into the parent thread's flat cell list of this node's parent
    /// (`nil` for the root). Used by zoom: clicking a cell rescopes to that
    /// subtree so callers above stay visible at the top.
    let parentIndex: Int?
}

/// Flat list of cells for one thread, plus the thread's display info. Holding
/// a single root + children-by-index keeps zoom math trivial and avoids
/// re-walking the SampleTreeNode tree on every redraw.
struct FlamegraphThread: Identifiable, Sendable, Equatable {
    static func == (lhs: FlamegraphThread, rhs: FlamegraphThread) -> Bool {
        lhs.id == rhs.id && lhs.totalSamples == rhs.totalSamples && lhs.cells.count == rhs.cells.count
    }

    let id: UUID
    let label: String
    let totalSamples: Int
    let cells: [FlamegraphCell]
    /// `cells[childrenOf[i]]` are the immediate children of `cells[i]`.
    let childrenOf: [[Int]]
    let maxDepth: Int

    /// Subset/rescope to the subtree rooted at `cellIndex` for click-zoom.
    /// The returned thread normalizes that subtree to span [0,1] and shifts
    /// depths so the clicked cell becomes depth 0.
    func zoomed(toCellIndex cellIndex: Int) -> FlamegraphThread {
        guard cells.indices.contains(cellIndex) else { return self }
        let root = cells[cellIndex]
        let totalWidth = root.widthRatio
        guard totalWidth > 0 else { return self }
        let baseX = root.xRatio
        let baseDepth = root.depth

        var newCells: [FlamegraphCell] = []
        var newChildren: [[Int]] = []
        var oldToNew: [Int: Int] = [:]

        // BFS so children are appended after their parent in deterministic order.
        var queue: [Int] = [cellIndex]
        while let oldIdx = queue.first {
            queue.removeFirst()
            let cell = cells[oldIdx]
            let newIdx = newCells.count
            oldToNew[oldIdx] = newIdx
            let newParent: Int? = (oldIdx == cellIndex) ? nil : oldToNew[childParentLookup(forChildOldIdx: oldIdx)]
            newCells.append(FlamegraphCell(
                id: cell.id,
                symbol: cell.symbol,
                module: cell.module,
                sampleCount: cell.sampleCount,
                depth: cell.depth - baseDepth,
                xRatio: (cell.xRatio - baseX) / totalWidth,
                widthRatio: cell.widthRatio / totalWidth,
                parentIndex: newParent
            ))
            newChildren.append([])
            for child in childrenOf[oldIdx] {
                queue.append(child)
            }
        }

        // Wire children using the new index map.
        for (oldIdx, newIdx) in oldToNew {
            for child in childrenOf[oldIdx] {
                if let mapped = oldToNew[child] {
                    newChildren[newIdx].append(mapped)
                }
            }
        }

        let depth = newCells.map(\.depth).max() ?? 0
        return FlamegraphThread(
            id: id,
            label: label,
            totalSamples: root.sampleCount,
            cells: newCells,
            childrenOf: newChildren,
            maxDepth: depth
        )
    }

    private func childParentLookup(forChildOldIdx childIdx: Int) -> Int {
        // childrenOf is keyed by parent old index; find which parent owns `childIdx`.
        // Linear scan is fine — typical max children-per-frame is small.
        for (parent, kids) in childrenOf.enumerated() where kids.contains(childIdx) {
            return parent
        }
        return childIdx
    }
}

enum FlamegraphLayout {
    /// Build per-thread cell lists from parsed `sample` output.
    static func build(from threads: [SampleTreeNode]) -> [FlamegraphThread] {
        threads.compactMap { build(thread: $0) }
    }

    private static func build(thread: SampleTreeNode) -> FlamegraphThread? {
        guard thread.sampleCount > 0 else { return nil }

        var cells: [FlamegraphCell] = []
        var childrenOf: [[Int]] = []
        var maxDepth = 0

        // Recursive layout: place each subtree at (xRatio, widthRatio), append
        // a cell, recurse for children at depth+1. Children share their
        // parent's x range proportional to their sampleCount.
        func place(_ node: SampleTreeNode, depth: Int, xRatio: Double, widthRatio: Double, parent: Int?) -> Int {
            let index = cells.count
            cells.append(FlamegraphCell(
                id: node.id,
                symbol: node.symbol,
                module: node.module,
                sampleCount: node.sampleCount,
                depth: depth,
                xRatio: xRatio,
                widthRatio: widthRatio,
                parentIndex: parent
            ))
            childrenOf.append([])
            if depth > maxDepth { maxDepth = depth }

            // Each child's width is proportional to (child / parent), NOT (child /
            // sum_of_children). That way frames with self-time show a visible gap
            // after their last child — same convention as Brendan Gregg / Instruments.
            guard !node.children.isEmpty, node.sampleCount > 0 else { return index }

            var cursor = xRatio
            let unit = widthRatio / Double(node.sampleCount)
            for child in node.children {
                let w = Double(child.sampleCount) * unit
                let childIndex = place(child, depth: depth + 1, xRatio: cursor, widthRatio: w, parent: index)
                childrenOf[index].append(childIndex)
                cursor += w
            }
            return index
        }

        _ = place(thread, depth: 0, xRatio: 0.0, widthRatio: 1.0, parent: nil)

        return FlamegraphThread(
            id: thread.id,
            label: thread.symbol,
            totalSamples: thread.sampleCount,
            cells: cells,
            childrenOf: childrenOf,
            maxDepth: maxDepth
        )
    }
}

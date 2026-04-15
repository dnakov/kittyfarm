import SwiftUI

/// A proportional flow layout that maximizes device size.
///
/// For each possible number of rows (1..N), it finds the optimal partition
/// of items into rows using linear partition, computes the resulting row height,
/// and picks the configuration that maximizes area usage.
struct MasonryLayout: Layout {
    var spacing: CGFloat
    var availableHeight: CGFloat?

    init(columnMinWidth: CGFloat = 220, spacing: CGFloat = 16, availableHeight: CGFloat? = nil) {
        self.spacing = spacing
        self.availableHeight = availableHeight
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let totalWidth = proposal.width ?? 800
        return computeLayout(totalWidth: totalWidth, subviews: subviews).totalSize
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(totalWidth: bounds.width, subviews: subviews)

        for (index, subview) in subviews.enumerated() {
            guard index < result.placements.count else { break }
            let p = result.placements[index]
            subview.place(
                at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y),
                proposal: ProposedViewSize(width: p.w, height: p.h)
            )
        }
    }

    // MARK: - Private

    private struct Placement {
        var x: CGFloat; var y: CGFloat; var w: CGFloat; var h: CGFloat
    }

    private struct LayoutResult {
        var placements: [Placement]
        var totalSize: CGSize
    }

    private func computeLayout(totalWidth: CGFloat, subviews: Subviews) -> LayoutResult {
        guard !subviews.isEmpty else {
            return LayoutResult(placements: [], totalSize: .zero)
        }

        // Measure each subview's aspect ratio (width / height).
        let refW: CGFloat = 300
        let ratios: [CGFloat] = subviews.map { sv in
            let size = sv.sizeThatFits(ProposedViewSize(width: refW, height: nil))
            return size.height > 0 ? refW / size.height : 0.5
        }

        let maxH = availableHeight ?? 99999

        // Try every possible number of rows. For each, find the optimal
        // partition and compute the effective row height — the smaller of
        // the width-constrained height and the height-constrained height.
        // Pick the configuration that gives the largest effective row height.
        let n = ratios.count
        var bestPartition: [[Int]] = (0..<n).map { [$0] }
        var bestEffectiveHeight: CGFloat = 0

        for numRows in 1...n {
            let partition = linearPartition(ratios: ratios, k: numRows, totalWidth: totalWidth)
            let actualRows = partition.count

            // Height constrained by width: the widest row limits the height
            let widthConstrainedH = minRowHeight(partition: partition, ratios: ratios, totalWidth: totalWidth)

            // Height constrained by available space
            let heightConstrainedH = (maxH - spacing * CGFloat(max(actualRows - 1, 0))) / CGFloat(actualRows)

            // Effective height is the smaller constraint
            let effectiveH = min(widthConstrainedH, heightConstrainedH)

            if effectiveH > bestEffectiveHeight {
                bestEffectiveHeight = effectiveH
                bestPartition = partition
            }
        }

        return placePartition(bestPartition, ratios: ratios, totalWidth: totalWidth, maxRowHeight: bestEffectiveHeight)
    }

    // MARK: - Linear Partition (Knuth)

    /// Partition `n` items into `k` rows to minimize the maximum row "weight",
    /// where each row's weight is the sum of aspect ratios of its items.
    /// This ensures the tallest row is as short as possible, which means
    /// the shared row height is as large as possible.
    private func linearPartition(ratios: [CGFloat], k: Int, totalWidth: CGFloat) -> [[Int]] {
        let n = ratios.count
        if k >= n {
            // Each item gets its own row
            return (0..<n).map { [$0] }
        }
        if k == 1 {
            return [Array(0..<n)]
        }

        // weights[i] = sum of ratios[0..i] — the "width" each item needs at height=1
        // For a row spanning items i..j, the row height when scaled to totalWidth is:
        //   h = (totalWidth - spacing*(count-1)) / sum(ratios[i..j])
        // To maximize the minimum row height, we want to minimize the maximum
        // sum of ratios in any row (since height = totalWidth / sumRatios).

        // DP: partition first i items into j groups, minimizing max group sum.
        // dp[i][j] = minimum possible maximum-sum when partitioning items 0..<i into j groups
        var prefixSum = [CGFloat](repeating: 0, count: n + 1)
        for i in 0..<n {
            prefixSum[i + 1] = prefixSum[i] + ratios[i]
        }

        func rangeSum(_ from: Int, _ to: Int) -> CGFloat {
            prefixSum[to] - prefixSum[from]
        }

        var dp = [[CGFloat]](repeating: [CGFloat](repeating: .infinity, count: k + 1), count: n + 1)
        var split = [[Int]](repeating: [Int](repeating: 0, count: k + 1), count: n + 1)

        dp[0][0] = 0

        for i in 1...n {
            dp[i][1] = rangeSum(0, i)
            guard i >= 2 else { continue }
            for j in 2...min(i, k) {
                for m in (j - 1)..<i {
                    let cost = max(dp[m][j - 1], rangeSum(m, i))
                    if cost < dp[i][j] {
                        dp[i][j] = cost
                        split[i][j] = m
                    }
                }
            }
        }

        // Reconstruct partition
        var result: [[Int]] = []
        var remaining = n
        var groups = k

        while groups > 0 {
            let start = split[remaining][groups]
            result.append(Array(start..<remaining))
            remaining = start
            groups -= 1
        }

        result.reverse()
        return result
    }

    /// For a given partition, compute the row height if all rows are scaled to
    /// fill totalWidth. The binding constraint is the row with the most "weight"
    /// (sum of ratios) — it produces the shortest height. Return that min height.
    private func minRowHeight(partition: [[Int]], ratios: [CGFloat], totalWidth: CGFloat) -> CGFloat {
        var minH: CGFloat = .infinity

        for row in partition {
            let sumRatio = row.reduce(CGFloat(0)) { $0 + ratios[$1] }
            let rowSpacing = spacing * CGFloat(max(row.count - 1, 0))
            let available = totalWidth - rowSpacing
            let h = available / max(sumRatio, 0.001)
            minH = min(minH, h)
        }

        return minH
    }

    private func placePartition(_ partition: [[Int]], ratios: [CGFloat], totalWidth: CGFloat, maxRowHeight: CGFloat? = nil) -> LayoutResult {
        let n = ratios.count
        // All rows share the same height
        let unconstrained = minRowHeight(partition: partition, ratios: ratios, totalWidth: totalWidth)
        let rowHeight = maxRowHeight ?? unconstrained

        var placements = Array(repeating: Placement(x: 0, y: 0, w: 0, h: 0), count: n)
        var y: CGFloat = 0

        for row in partition {
            // Each item's width = ratio * rowHeight; then center the row
            let itemWidths = row.map { ratios[$0] * rowHeight }
            let rowSpacing = spacing * CGFloat(max(row.count - 1, 0))
            let rowWidth = itemWidths.reduce(0, +) + rowSpacing
            var x = max((totalWidth - rowWidth) / 2, 0)

            for (i, idx) in row.enumerated() {
                placements[idx] = Placement(x: x, y: y, w: itemWidths[i], h: rowHeight)
                x += itemWidths[i] + spacing
            }

            y += rowHeight + spacing
        }

        return LayoutResult(
            placements: placements,
            totalSize: CGSize(width: totalWidth, height: max(y - spacing, 0))
        )
    }
}

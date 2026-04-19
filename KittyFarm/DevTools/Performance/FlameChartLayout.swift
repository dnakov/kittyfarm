import Foundation

/// One time-ordered rectangle in the flame chart. Unlike `FlamegraphCell`,
/// `startNs..endNs` are real timestamps (ns from the trace start) — not an
/// arbitrary share of total samples.
struct FlameChartCell: Identifiable, Sendable {
    let id: UUID
    let symbol: String
    let module: String?
    let depth: Int
    let startNs: UInt64
    let endNs: UInt64
    var durationNs: UInt64 { endNs > startNs ? endNs - startNs : 0 }
}

/// Per-thread flame chart, time-ordered.
struct FlameChartThread: Identifiable, Sendable, Equatable {
    let id: UInt64
    let label: String
    let startNs: UInt64
    let endNs: UInt64
    let cells: [FlameChartCell]
    let maxDepth: Int
    let sampleCount: Int

    var durationNs: UInt64 { endNs > startNs ? endNs - startNs : 0 }

    static func == (lhs: FlameChartThread, rhs: FlameChartThread) -> Bool {
        lhs.id == rhs.id && lhs.cells.count == rhs.cells.count && lhs.endNs == rhs.endNs
    }
}

enum FlameChartLayout {
    /// Coalesce time-stamped samples into time-spanning rectangles. The
    /// algorithm walks samples chronologically, keeping a "currently open"
    /// stack. Frames that match between consecutive samples extend; frames
    /// that diverge close out and new frames open.
    ///
    /// Gap handling: if two samples are more than `maxGapNs` apart, treat the
    /// stack as having unwound between them — close everything before the new
    /// sample. Otherwise, very long sleeps would render as one giant rectangle.
    static func build(
        from trace: TimeProfileTrace,
        maxGapNs: UInt64 = 50_000_000     // 50 ms — much greater than 1 ms sample interval
    ) -> [FlameChartThread] {
        trace.threads.compactMap { build(thread: $0, traceStartNs: trace.startNs, maxGapNs: maxGapNs) }
    }

    private static func build(
        thread: TimeProfileThread,
        traceStartNs: UInt64,
        maxGapNs: UInt64
    ) -> FlameChartThread? {
        guard !thread.samples.isEmpty else { return nil }

        struct OpenFrame {
            let symbol: String
            let module: String?
            let depth: Int
            let startNs: UInt64
        }

        var openStack: [OpenFrame] = []
        var output: [FlameChartCell] = []
        var maxDepth = 0
        var prevSampleNs: UInt64 = thread.samples.first!.timestampNs

        // Each sample is leaf-first. Reverse to get root-at-depth-0.
        func rootFirstStack(from sample: TimeProfileSample) -> [TimeProfileFrame] {
            Array(sample.backtrace.reversed())
        }

        func closeFrames(downToDepth keep: Int, atTime endNs: UInt64) {
            while openStack.count > keep {
                let f = openStack.removeLast()
                output.append(FlameChartCell(
                    id: UUID(),
                    symbol: f.symbol,
                    module: f.module,
                    depth: f.depth,
                    startNs: f.startNs,
                    endNs: max(endNs, f.startNs + 1)   // visible sliver even for instantaneous frames
                ))
            }
        }

        for sample in thread.samples {
            let nowNs = sample.timestampNs
            let gap = nowNs > prevSampleNs ? nowNs - prevSampleNs : 0

            // If the thread was idle for more than maxGapNs, the stack we'd been
            // tracking probably unwound — close everything at the prior sample
            // time before opening fresh frames.
            if gap > maxGapNs {
                closeFrames(downToDepth: 0, atTime: prevSampleNs + maxGapNs)
            }

            let stack = rootFirstStack(from: sample)

            // Common prefix length with the currently open stack
            var commonLen = 0
            let maxCommon = Swift.min(stack.count, openStack.count)
            for i in 0..<maxCommon {
                if stack[i].symbol == openStack[i].symbol &&
                   stack[i].module == openStack[i].module {
                    commonLen += 1
                } else {
                    break
                }
            }

            // Close diverged tail
            closeFrames(downToDepth: commonLen, atTime: nowNs)

            // Open new frames from commonLen up
            for offset in commonLen..<stack.count {
                let frame = stack[offset]
                let depth = offset
                openStack.append(OpenFrame(
                    symbol: frame.symbol,
                    module: frame.module,
                    depth: depth,
                    startNs: nowNs
                ))
                if depth > maxDepth { maxDepth = depth }
            }

            prevSampleNs = nowNs
        }

        // Close everything at the last sample's time + one weight tick.
        let lastSample = thread.samples.last!
        let traceEndNs = lastSample.timestampNs + Swift.max(lastSample.weightNs, 1_000_000)
        closeFrames(downToDepth: 0, atTime: traceEndNs)

        let firstSampleNs = thread.samples.first!.timestampNs

        return FlameChartThread(
            id: thread.id,
            label: thread.label,
            startNs: firstSampleNs,
            endNs: traceEndNs,
            cells: output,
            maxDepth: maxDepth,
            sampleCount: thread.samples.count
        )
    }
}

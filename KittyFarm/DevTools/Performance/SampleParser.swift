import Foundation

enum SampleParser {
    static func parse(_ text: String) -> [SampleTreeNode] {
        guard let callGraphRange = text.range(of: "Call graph:") else {
            log(text)
            return []
        }

        let body = text[callGraphRange.upperBound...]
        let lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)

        var threads: [ThreadBuilder] = []
        var currentThread: ThreadBuilder?
        var stack: [FrameBuilder] = []

        for rawLine in lines {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }

            if line.hasPrefix("Binary Images:") || line.hasPrefix("Total number in stack") {
                break
            }

            if let parsed = parseFrameLine(line) {
                if let thread = currentThread {
                    attach(frame: parsed.frame, depth: parsed.depth, thread: thread, stack: &stack)
                }
                continue
            }

            if let thread = parseThreadLine(line) {
                if let prev = currentThread {
                    flushStack(&stack, into: prev)
                    threads.append(prev)
                }
                currentThread = thread
                stack.removeAll()
                continue
            }
        }

        if let prev = currentThread {
            flushStack(&stack, into: prev)
            threads.append(prev)
        }

        if threads.isEmpty {
            log(text)
        }

        return threads.map { $0.build() }
    }

    private struct FrameBuilder {
        let depth: Int
        let symbol: String
        let module: String?
        let sampleCount: Int
        var children: [FrameBuilder] = []

        func build() -> SampleTreeNode {
            let childSum = children.reduce(0) { $0 + $1.sampleCount }
            let selfSamples = max(0, sampleCount - childSum)
            return SampleTreeNode(
                symbol: symbol,
                module: module,
                sampleCount: sampleCount,
                selfSampleCount: selfSamples,
                children: children.map { $0.build() }
            )
        }
    }

    private final class ThreadBuilder {
        let label: String
        let sampleCount: Int
        var roots: [FrameBuilder] = []

        init(label: String, sampleCount: Int) {
            self.label = label
            self.sampleCount = sampleCount
        }

        func build() -> SampleTreeNode {
            let childSum = roots.reduce(0) { $0 + $1.sampleCount }
            let selfSamples = max(0, sampleCount - childSum)
            return SampleTreeNode(
                symbol: label,
                module: nil,
                sampleCount: sampleCount,
                selfSampleCount: selfSamples,
                children: roots.map { $0.build() }
            )
        }
    }

    private static func attach(
        frame: FrameBuilder,
        depth: Int,
        thread: ThreadBuilder,
        stack: inout [FrameBuilder]
    ) {
        while stack.count >= depth, let last = stack.popLast() {
            if let parentIdx = stack.indices.last {
                stack[parentIdx].children.append(last)
            } else {
                thread.roots.append(last)
            }
        }

        stack.append(frame)
    }

    private static func flushStack(_ stack: inout [FrameBuilder], into thread: ThreadBuilder) {
        while let last = stack.popLast() {
            if let parentIdx = stack.indices.last {
                stack[parentIdx].children.append(last)
            } else {
                thread.roots.append(last)
            }
        }
    }

    private static func parseThreadLine(_ line: String) -> ThreadBuilder? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("+") else { return nil }

        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard let count = parts.first.flatMap(Int.init) else { return nil }
        let label = parts.count > 1 ? parts[1] : "Thread"
        return ThreadBuilder(label: label, sampleCount: count)
    }

    private struct ParsedFrame {
        let frame: FrameBuilder
        let depth: Int
    }

    private static func parseFrameLine(_ line: String) -> ParsedFrame? {
        let scalars = line.unicodeScalars
        var index = scalars.startIndex
        var leadingSpaces = 0
        while index < scalars.endIndex, scalars[index] == " " {
            leadingSpaces += 1
            index = scalars.index(after: index)
        }

        guard index < scalars.endIndex, scalars[index] == "+" else { return nil }
        index = scalars.index(after: index)

        var innerSpaces = 0
        while index < scalars.endIndex, scalars[index] == " " {
            innerSpaces += 1
            index = scalars.index(after: index)
        }

        guard innerSpaces >= 1 else { return nil }
        let depth = max(1, (innerSpaces + 1) / 2)

        let remainder = String(scalars[index...])
        let trimmedRemainder = remainder.trimmingCharacters(in: .whitespaces)
        guard !trimmedRemainder.isEmpty else { return nil }

        let parts = trimmedRemainder.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard let count = parts.first.flatMap(Int.init), parts.count > 1 else { return nil }

        let tail = parts[1]
        let (symbol, module) = splitSymbolAndModule(tail)

        return ParsedFrame(
            frame: FrameBuilder(
                depth: depth,
                symbol: symbol,
                module: module,
                sampleCount: count
            ),
            depth: depth
        )
    }

    private static func splitSymbolAndModule(_ tail: String) -> (symbol: String, module: String?) {
        guard let inRange = tail.range(of: "  (in ") ?? tail.range(of: " (in ") else {
            return (stripOffsetAndAddress(tail), nil)
        }

        let symbolRaw = String(tail[..<inRange.lowerBound])
        let afterIn = tail[inRange.upperBound...]
        guard let closeIdx = afterIn.firstIndex(of: ")") else {
            return (symbolRaw.trimmingCharacters(in: .whitespaces), nil)
        }
        let module = String(afterIn[..<closeIdx])
        return (symbolRaw.trimmingCharacters(in: .whitespaces), module)
    }

    private static func stripOffsetAndAddress(_ text: String) -> String {
        var result = text
        if let plusRange = result.range(of: " + ", options: .backwards) {
            result = String(result[..<plusRange.lowerBound])
        }
        if let bracket = result.range(of: "  [", options: .backwards) {
            result = String(result[..<bracket.lowerBound])
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func log(_ text: String) {
        let preview = String(text.prefix(500))
        print("SampleParser: failed to parse sample output. First 500 chars:\n\(preview)")
    }
}

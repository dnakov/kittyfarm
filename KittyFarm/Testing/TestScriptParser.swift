import Foundation

enum TestScriptParseError: LocalizedError {
    case unknownCommand(line: Int, text: String)

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let line, let text):
            return "Line \(line): Unknown command: \(text)"
        }
    }
}

struct TestScriptParser {
    static func parse(_ script: String) throws -> [TestAction] {
        var actions: [TestAction] = []

        // Normalize smart quotes (macOS auto-replaces " with " and ")
        // and smart apostrophes so pasted/auto-substituted text still parses.
        let normalizedScript = script
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")

        for (index, rawLine) in normalizedScript.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let lineNumber = index + 1

            if let action = parseLine(line) {
                actions.append(action)
            } else {
                throw TestScriptParseError.unknownCommand(line: lineNumber, text: line)
            }
        }

        return actions
    }

    private static func parseLine(_ line: String) -> TestAction? {
        let lowered = line.lowercased()

        if lowered.hasPrefix("tap ") {
            guard let element = extractQuoted(from: line, after: "tap ") else { return nil }
            return .tap(element: element)
        }

        if lowered.hasPrefix("double tap ") {
            guard let element = extractQuoted(from: line, after: "double tap ") else { return nil }
            return .doubleTap(element: element)
        }

        if lowered.hasPrefix("long press ") {
            guard let element = extractQuoted(from: line, after: "long press ") else { return nil }
            return .longPress(element: element)
        }

        if lowered.hasPrefix("type ") {
            return parseType(line)
        }

        if lowered.hasPrefix("swipe ") {
            return parseSwipe(line)
        }

        if lowered.hasPrefix("wait for ") {
            return parseWaitFor(line)
        }

        if lowered.hasPrefix("assert not visible ") {
            guard let element = extractQuoted(from: line, after: "assert not visible ") else { return nil }
            return .assertNotVisible(element: element)
        }

        if lowered.hasPrefix("assert visible ") {
            guard let element = extractQuoted(from: line, after: "assert visible ") else { return nil }
            return .assertVisible(element: element)
        }

        if lowered == "press home" {
            return .pressHome
        }

        if lowered.hasPrefix("pause ") {
            let rest = line.dropFirst("pause ".count).trimmingCharacters(in: .whitespaces)
            guard let duration = TimeInterval(rest), duration > 0 else { return nil }
            return .pause(duration: duration)
        }

        if lowered.hasPrefix("open ") {
            guard let app = extractQuoted(from: line, after: "open ") else { return nil }
            return .open(app: app)
        }

        return nil
    }

    private static func parseType(_ line: String) -> TestAction? {
        let rest = String(line.dropFirst("type ".count))
        let quotes = extractAllQuoted(from: rest)

        guard let text = quotes.first else { return nil }

        if quotes.count >= 2,
           rest.lowercased().contains(" in ") {
            return .type(text: text, element: quotes[1])
        }

        return .type(text: text, element: nil)
    }

    private static func parseSwipe(_ line: String) -> TestAction? {
        let rest = line.dropFirst("swipe ".count).trimmingCharacters(in: .whitespaces)
        let lowered = rest.lowercased()

        let directions: [(String, TestAction.SwipeDirection)] = [
            ("up", .up), ("down", .down), ("left", .left), ("right", .right)
        ]

        for (name, direction) in directions {
            if lowered.hasPrefix(name) {
                let afterDirection = rest.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
                if afterDirection.isEmpty {
                    return .swipe(direction: direction, element: nil)
                }
                if afterDirection.lowercased().hasPrefix("on ") {
                    let element = extractQuoted(from: String(afterDirection), after: "on ")
                    return .swipe(direction: direction, element: element)
                }
                return .swipe(direction: direction, element: nil)
            }
        }

        return nil
    }

    private static func parseWaitFor(_ line: String) -> TestAction? {
        let rest = String(line.dropFirst("wait for ".count))
        guard let element = extractAllQuoted(from: rest).first else { return nil }

        let lowered = rest.lowercased()
        if let timeoutRange = lowered.range(of: "timeout ") {
            let timeoutStr = rest[timeoutRange.upperBound...].trimmingCharacters(in: .whitespaces)
            if let timeout = TimeInterval(timeoutStr) {
                return .waitFor(element: element, timeout: timeout)
            }
        }

        return .waitFor(element: element, timeout: nil)
    }

    private static func extractQuoted(from string: String, after prefix: String) -> String? {
        let rest = String(string.dropFirst(prefix.count))
        return extractAllQuoted(from: rest).first
    }

    private static func extractAllQuoted(from string: String) -> [String] {
        var results: [String] = []
        var remaining = string[...]

        while let openQuote = remaining.firstIndex(of: "\"") {
            let afterOpen = remaining.index(after: openQuote)
            guard afterOpen < remaining.endIndex,
                  let closeQuote = remaining[afterOpen...].firstIndex(of: "\"") else {
                break
            }
            results.append(String(remaining[afterOpen..<closeQuote]))
            remaining = remaining[remaining.index(after: closeQuote)...]
        }

        return results
    }
}

import Foundation

struct ResolvedElement: Sendable {
    let element: AccessibilityElement
    let normalizedX: Double
    let normalizedY: Double
}

enum ElementResolverError: LocalizedError {
    case elementNotFound(String)

    var errorDescription: String? {
        switch self {
        case .elementNotFound(let query):
            return "Element not found: \"\(query)\""
        }
    }
}

struct ElementResolver {
    static func resolve(
        _ query: String,
        in tree: [AccessibilityElement],
        screenWidth: Double,
        screenHeight: Double
    ) throws -> ResolvedElement {
        let flat = flatten(tree)
        let matches = rank(query: query, candidates: flat)

        guard let best = matches.first else {
            throw ElementResolverError.elementNotFound(query)
        }

        let nx = best.frame.midX / screenWidth
        let ny = best.frame.midY / screenHeight

        return ResolvedElement(
            element: best,
            normalizedX: min(max(nx, 0), 1),
            normalizedY: min(max(ny, 0), 1)
        )
    }

    static func exists(_ query: String, in tree: [AccessibilityElement]) -> Bool {
        let flat = flatten(tree)
        return !rank(query: query, candidates: flat).isEmpty
    }

    private static func flatten(_ elements: [AccessibilityElement]) -> [AccessibilityElement] {
        var result: [AccessibilityElement] = []
        for element in elements {
            if element.frame.width > 0 && element.frame.height > 0 {
                result.append(element)
            }
            result.append(contentsOf: flatten(element.children))
        }
        return result
    }

    private static func rank(query: String, candidates: [AccessibilityElement]) -> [AccessibilityElement] {
        struct ScoredElement {
            let element: AccessibilityElement
            let score: Int
        }

        let loweredQuery = query.lowercased()

        let scored = candidates.compactMap { element -> ScoredElement? in
            let score = matchScore(query: loweredQuery, element: element)
            guard score > 0 else { return nil }
            return ScoredElement(element: element, score: score)
        }

        return scored
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                if a.element.isInteractive != b.element.isInteractive {
                    return a.element.isInteractive
                }
                let aLen = a.element.label.count + a.element.identifier.count
                let bLen = b.element.label.count + b.element.identifier.count
                return aLen < bLen
            }
            .map(\.element)
    }

    private static func matchScore(query: String, element: AccessibilityElement) -> Int {
        let fields = [
            element.label.lowercased(),
            element.identifier.lowercased(),
            element.value?.lowercased() ?? ""
        ].filter { !$0.isEmpty }

        var bestScore = 0

        for field in fields {
            if field == query {
                bestScore = max(bestScore, 100)
            } else if field.caseInsensitiveCompare(query) == .orderedSame {
                bestScore = max(bestScore, 90)
            } else if field.contains(query) {
                bestScore = max(bestScore, 50)
            }
        }

        return bestScore
    }
}

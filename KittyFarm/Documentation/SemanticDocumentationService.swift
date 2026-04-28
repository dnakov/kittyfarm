import Foundation

enum SemanticDocumentationError: LocalizedError {
    case unavailable(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .invalidResponse(let message):
            message
        }
    }
}

protocol SemanticDocumentationServicing: Sendable {
    func availability() -> SemanticDocumentationService.Availability
    func search(
        query: String,
        frameworks: [String],
        kinds: [String],
        limit: Int,
        omitContent: Bool
    ) throws -> [SemanticDocumentationResult]
    func get(identifier: String) throws -> SemanticDocumentationResult
}

final class SemanticDocumentationService: Sendable {
    struct Availability: Sendable {
        let isAvailable: Bool
        let errorMessage: String?
    }

    private struct SearchPayload: Decodable {
        let results: [SemanticDocumentationResult]
    }

    func availability() -> Availability {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let available = doq_docs_available(&errorPointer) == 1
        let message = Self.consumeCString(errorPointer)
        return Availability(isAvailable: available, errorMessage: available ? nil : message)
    }

    func search(
        query: String,
        frameworks: [String] = [],
        kinds: [String] = [],
        limit: Int = 10,
        omitContent: Bool = false
    ) throws -> [SemanticDocumentationResult] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        var errorPointer: UnsafeMutablePointer<CChar>?
        let frameworkJSON = try jsonString(frameworks)
        let kindJSON = try jsonString(kinds)
        let pointer = normalized.withCString { queryCString in
            frameworkJSON.withCString { frameworkCString in
                kindJSON.withCString { kindCString in
                    doq_docs_search_json(
                        queryCString,
                        frameworkCString,
                        kindCString,
                        Int32(max(1, min(limit, 25))),
                        omitContent,
                        &errorPointer
                    )
                }
            }
        }

        guard let pointer else {
            throw SemanticDocumentationError.unavailable(Self.consumeCString(errorPointer) ?? "Semantic documentation search is unavailable.")
        }
        defer { doq_docs_free(pointer) }

        let data = Data(bytes: pointer, count: strlen(pointer))
        do {
            return try JSONDecoder().decode([SemanticDocumentationResult].self, from: data)
        } catch {
            throw SemanticDocumentationError.invalidResponse(error.localizedDescription)
        }
    }

    func get(identifier: String) throws -> SemanticDocumentationResult {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw SemanticDocumentationError.invalidResponse("Documentation identifier is required.")
        }

        var errorPointer: UnsafeMutablePointer<CChar>?
        let pointer = normalized.withCString { doq_docs_get_json($0, &errorPointer) }
        guard let pointer else {
            throw SemanticDocumentationError.unavailable(Self.consumeCString(errorPointer) ?? "Documentation entry is unavailable.")
        }
        defer { doq_docs_free(pointer) }

        let data = Data(bytes: pointer, count: strlen(pointer))
        do {
            return try JSONDecoder().decode(SemanticDocumentationResult.self, from: data)
        } catch {
            throw SemanticDocumentationError.invalidResponse(error.localizedDescription)
        }
    }

    private func jsonString<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func consumeCString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { doq_docs_free(pointer) }
        return String(cString: pointer)
    }
}

extension SemanticDocumentationService: SemanticDocumentationServicing {}

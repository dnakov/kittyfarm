import Foundation

enum SymbolGraphParser {
    static func parse(data: Data, platform: DocumentationPlatform, sdkName: String) throws -> [IndexedDocumentationSymbol] {
        let graph = try JSONDecoder().decode(SymbolGraph.self, from: data)
        var memberOf: [String: String] = [:]
        for relationship in graph.relationships where relationship.kind == "memberOf" {
            memberOf[relationship.source, default: relationship.target] = relationship.target
        }

        return graph.symbols.compactMap { symbol in
            guard !symbol.spi, symbol.accessLevel != "private", symbol.accessLevel != "internal" else {
                return nil
            }
            let preciseID = symbol.identifier.precise
            guard !preciseID.isEmpty else { return nil }

            return IndexedDocumentationSymbol(
                name: symbol.names.title,
                kind: symbol.kind.identifier,
                kindDisplay: symbol.kind.displayName,
                module: graph.module.name,
                preciseID: preciseID,
                path: symbol.pathComponents.joined(separator: "/"),
                declaration: declarationString(symbol.declarationFragments),
                docComment: docCommentText(symbol.docComment),
                parentID: memberOf[preciseID],
                availability: availabilityString(symbol.availability),
                platforms: [platform],
                sdkNames: [sdkName]
            )
        }
    }

    static func parse(fileURL: URL, platform: DocumentationPlatform, sdkName: String) throws -> [IndexedDocumentationSymbol] {
        try parse(data: Data(contentsOf: fileURL), platform: platform, sdkName: sdkName)
    }

    private static func declarationString(_ fragments: [DeclarationFragment]) -> String {
        fragments.map(\.spelling).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func docCommentText(_ comment: DocComment?) -> String {
        guard let comment else { return "" }
        return comment.lines
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func availabilityString(_ availability: [Availability]) -> String {
        guard !availability.isEmpty,
              let data = try? JSONEncoder().encode(availability),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }
}

struct IndexedDocumentationSymbol: Codable, Equatable, Sendable {
    let name: String
    let kind: String
    let kindDisplay: String
    let module: String
    let preciseID: String
    let path: String
    let declaration: String
    let docComment: String
    let parentID: String?
    let availability: String
    let platforms: [DocumentationPlatform]
    let sdkNames: [String]
}

private struct SymbolGraph: Decodable {
    let module: Module
    let symbols: [Symbol]
    let relationships: [Relationship]
}

private struct Module: Decodable {
    let name: String
}

private struct Symbol: Decodable {
    let identifier: SymbolIdentifier
    let names: SymbolNames
    let kind: SymbolKind
    let pathComponents: [String]
    let declarationFragments: [DeclarationFragment]
    let docComment: DocComment?
    let accessLevel: String?
    let spi: Bool
    let availability: [Availability]

    private enum CodingKeys: String, CodingKey {
        case identifier
        case names
        case kind
        case pathComponents
        case declarationFragments
        case docComment
        case accessLevel
        case spi
        case availability
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(SymbolIdentifier.self, forKey: .identifier)
        names = try container.decode(SymbolNames.self, forKey: .names)
        kind = try container.decode(SymbolKind.self, forKey: .kind)
        pathComponents = try container.decodeIfPresent([String].self, forKey: .pathComponents) ?? []
        declarationFragments = try container.decodeIfPresent([DeclarationFragment].self, forKey: .declarationFragments) ?? []
        docComment = try container.decodeIfPresent(DocComment.self, forKey: .docComment)
        accessLevel = try container.decodeIfPresent(String.self, forKey: .accessLevel)
        spi = try container.decodeIfPresent(Bool.self, forKey: .spi) ?? false
        availability = try container.decodeIfPresent([Availability].self, forKey: .availability) ?? []
    }
}

private struct SymbolIdentifier: Decodable {
    let precise: String
}

private struct SymbolNames: Decodable {
    let title: String
}

private struct SymbolKind: Decodable {
    let identifier: String
    let displayName: String
}

private struct DeclarationFragment: Codable, Equatable, Sendable {
    let spelling: String
}

private struct DocComment: Decodable {
    let lines: [DocCommentLine]
}

private struct DocCommentLine: Decodable {
    let text: String
}

private struct Availability: Codable, Equatable, Sendable {
    let domain: String?
    let introduced: Version?
    let deprecated: Version?
    let obsoleted: Version?
    let message: String?
    let renamed: String?
    let isUnconditionallyDeprecated: Bool?
    let isUnconditionallyUnavailable: Bool?
}

private struct Version: Codable, Equatable, Sendable {
    let major: Int?
    let minor: Int?
    let patch: Int?
}

private struct Relationship: Decodable {
    let kind: String
    let source: String
    let target: String
    let targetFallback: String?
}

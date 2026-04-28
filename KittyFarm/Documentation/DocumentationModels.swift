import Foundation

enum DocumentationPlatform: String, Codable, CaseIterable, Identifiable, Sendable {
    case macOS = "macos"
    case iOS = "ios"
    case watchOS = "watchos"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .macOS: "macOS"
        case .iOS: "iOS"
        case .watchOS: "watchOS"
        }
    }
}

enum DocumentationSearchMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case symbols
    case docs
    case all

    var id: String { rawValue }
}

struct DocumentationIndexStatus: Codable, Equatable, Sendable {
    var symbolCount: Int
    var indexedSDKs: [String]
    var indexedAt: Date?
    var semanticDocsAvailable: Bool
    var semanticDocsError: String?
    var failedModules: [DocumentationIndexFailure]

    static let empty = DocumentationIndexStatus(
        symbolCount: 0,
        indexedSDKs: [],
        indexedAt: nil,
        semanticDocsAvailable: false,
        semanticDocsError: nil,
        failedModules: []
    )
}

struct DocumentationIndexFailure: Codable, Equatable, Sendable, Identifiable {
    var id: String { "\(sdk)-\(module)" }
    let sdk: String
    let module: String
    let message: String
}

struct DocumentationSymbol: Codable, Equatable, Sendable, Identifiable {
    let rowID: Int64?
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
    let memberCount: Int
    let score: Double?

    var id: String { preciseID.isEmpty ? "\(module).\(path)" : preciseID }
}

struct SemanticDocumentationResult: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let framework: String?
    let kind: String?
    let title: String
    let content: String?
    let score: Double?
}

struct DocumentationSearchResult: Codable, Equatable, Sendable, Identifiable {
    enum ResultType: String, Codable, Sendable {
        case symbol
        case documentation
    }

    let id: String
    let type: ResultType
    let title: String
    let moduleOrFramework: String
    let kind: String
    let platforms: [DocumentationPlatform]
    let declaration: String?
    let snippet: String?
    let identifier: String
    let score: Double?
}

struct DocumentationSearchResponse: Codable, Equatable, Sendable {
    let results: [DocumentationSearchResult]
    let indexStatus: DocumentationIndexStatus
}

struct DocumentationSearchRequest: Codable, Equatable, Sendable {
    let query: String
    let mode: DocumentationSearchMode
    let platform: DocumentationPlatform?
    let limit: Int

    init(
        query: String,
        mode: DocumentationSearchMode = .all,
        platform: DocumentationPlatform? = nil,
        limit: Int = 10
    ) {
        self.query = query
        self.mode = mode
        self.platform = platform
        self.limit = max(1, min(limit, 25))
    }
}

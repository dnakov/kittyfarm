import Foundation

actor DocumentationSearchService {
    private let store: DocumentationIndexStore
    private let semanticService: any SemanticDocumentationServicing
    private let indexer: DocumentationIndexer

    init(
        store: DocumentationIndexStore? = nil,
        semanticService: any SemanticDocumentationServicing = SemanticDocumentationService()
    ) throws {
        let resolvedStore = try store ?? DocumentationIndexStore()
        self.store = resolvedStore
        self.semanticService = semanticService
        self.indexer = DocumentationIndexer(store: resolvedStore)
    }

    func status() async -> DocumentationIndexStatus {
        let semanticAvailability = semanticService.availability()
        do {
            return try store.status(
                semanticAvailable: semanticAvailability.isAvailable,
                semanticError: semanticAvailability.errorMessage
            )
        } catch {
            return DocumentationIndexStatus(
                symbolCount: 0,
                indexedSDKs: [],
                indexedAt: nil,
                semanticDocsAvailable: semanticAvailability.isAvailable,
                semanticDocsError: semanticAvailability.errorMessage ?? error.localizedDescription,
                failedModules: []
            )
        }
    }

    func search(_ request: DocumentationSearchRequest) async throws -> DocumentationSearchResponse {
        let normalized = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return DocumentationSearchResponse(results: [], indexStatus: await status())
        }

        var results: [DocumentationSearchResult] = []
        if request.mode == .symbols || request.mode == .all {
            let symbols = try store.searchSymbols(query: normalized, platform: request.platform, limit: request.limit)
            results += symbols.map(Self.result(from:))
        }

        if request.mode == .docs || request.mode == .all {
            let availability = semanticService.availability()
            if availability.isAvailable {
                let remaining = max(1, request.limit - results.count)
                let docs = try semanticService.search(
                    query: normalized,
                    frameworks: [],
                    kinds: [],
                    limit: request.mode == .all ? remaining : request.limit,
                    omitContent: false
                )
                results += docs.map(Self.result(from:))
            }
        }

        return DocumentationSearchResponse(
            results: Array(results.prefix(request.limit)),
            indexStatus: await status()
        )
    }

    func rebuildDefaultIndex(progress: DocumentationIndexer.ProgressHandler? = nil) async throws -> DocumentationIndexBuildResult {
        try await indexer.rebuildDefaultIndex(progress: progress)
    }

    func rebuildAllFrameworkIndex(progress: DocumentationIndexer.ProgressHandler? = nil) async throws -> DocumentationIndexBuildResult {
        try await indexer.rebuildAllFrameworkIndex(progress: progress)
    }

    private static func result(from symbol: DocumentationSymbol) -> DocumentationSearchResult {
        DocumentationSearchResult(
            id: "symbol:\(symbol.id)",
            type: .symbol,
            title: symbol.name,
            moduleOrFramework: symbol.module,
            kind: symbol.kindDisplay,
            platforms: symbol.platforms,
            declaration: symbol.declaration.nilIfEmpty,
            snippet: symbol.docComment.nilIfEmpty.map { truncate($0, maxLength: 260) },
            identifier: symbol.preciseID,
            score: symbol.score
        )
    }

    private static func result(from docs: SemanticDocumentationResult) -> DocumentationSearchResult {
        DocumentationSearchResult(
            id: "docs:\(docs.id)",
            type: .documentation,
            title: docs.title,
            moduleOrFramework: docs.framework ?? "",
            kind: docs.kind ?? "documentation",
            platforms: [],
            declaration: nil,
            snippet: docs.content?.nilIfEmpty.map { truncate($0, maxLength: 360) },
            identifier: docs.id,
            score: docs.score
        )
    }

    private static func truncate(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        let index = value.index(value.startIndex, offsetBy: maxLength)
        return String(value[..<index]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

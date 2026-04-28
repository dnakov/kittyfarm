import Foundation

@MainActor
extension KittyFarmStore {
    func documentationIndexStatus() async -> DocumentationIndexStatus {
        guard let documentationSearchService else {
            return DocumentationIndexStatus(
                symbolCount: 0,
                indexedSDKs: [],
                indexedAt: nil,
                semanticDocsAvailable: false,
                semanticDocsError: "Documentation search could not open its SQLite index.",
                failedModules: []
            )
        }
        return await documentationSearchService.status()
    }

    func searchDocumentation(_ request: DocumentationSearchRequest) async throws -> DocumentationSearchResponse {
        guard let documentationSearchService else {
            throw LocalControlStoreError.invalidRequest("Documentation search could not open its SQLite index.")
        }
        return try await documentationSearchService.search(request)
    }

    func localControlSearchDocumentation(_ request: LocalControlDocumentationSearchRequest) async throws -> DocumentationSearchResponse {
        let modeValue = request.mode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfEmpty ?? "all"
        guard let mode = DocumentationSearchMode(rawValue: modeValue) else {
            throw LocalControlStoreError.invalidRequest("mode must be one of: symbols, docs, all.")
        }

        let platformValue = request.platform?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfEmpty ?? "all"
        let platform: DocumentationPlatform?
        if platformValue == "all" {
            platform = nil
        } else if let parsedPlatform = DocumentationPlatform(rawValue: platformValue) {
            platform = parsedPlatform
        } else {
            throw LocalControlStoreError.invalidRequest("platform must be one of: macos, ios, watchos, all.")
        }

        return try await searchDocumentation(DocumentationSearchRequest(
            query: request.query,
            mode: mode,
            platform: platform,
            limit: request.limit ?? 10
        ))
    }

    func rebuildDocumentationIndex(includeAllFrameworks: Bool = false) async {
        guard let documentationSearchService else {
            documentationStatusMessage = "Documentation search could not open its SQLite index."
            return
        }

        isIndexingDocumentation = true
        documentationStatusMessage = includeAllFrameworks ? "Indexing all Apple SDK frameworks..." : "Indexing default Apple SDK frameworks..."
        documentationIndexProgressMessage = nil
        defer {
            isIndexingDocumentation = false
            documentationIndexProgressMessage = nil
        }

        do {
            let result: DocumentationIndexBuildResult
            if includeAllFrameworks {
                result = try await documentationSearchService.rebuildAllFrameworkIndex(progress: documentationProgressHandler())
            } else {
                result = try await documentationSearchService.rebuildDefaultIndex(progress: documentationProgressHandler())
            }
            let failed = result.failures.isEmpty ? "" : " \(result.failures.count) modules failed."
            documentationStatusMessage = "Indexed \(result.symbolCount) symbols from \(result.indexedSDKs.joined(separator: ", ")).\(failed)"
            appendBuildLog("[docs] \(documentationStatusMessage)", source: .system)
        } catch {
            documentationStatusMessage = "Documentation indexing failed: \(error.localizedDescription)"
            appendBuildLog("[docs] \(documentationStatusMessage)", source: .system, severity: .error)
        }
    }

    private func documentationProgressHandler() -> DocumentationIndexer.ProgressHandler {
        { [weak self] progress in
            await MainActor.run {
                self?.documentationIndexProgressMessage = "\(progress.message) (\(progress.completed)/\(progress.total))"
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

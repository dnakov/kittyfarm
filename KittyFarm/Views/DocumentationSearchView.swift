import SwiftUI

struct DocumentationSearchView: View {
    @Bindable var store: KittyFarmStore

    @State private var query = ""
    @State private var mode: DocumentationSearchMode = .symbols
    @State private var platformFilter = "all"
    @State private var results: [DocumentationSearchResult] = []
    @State private var selectedResultID: DocumentationSearchResult.ID?
    @State private var status: DocumentationIndexStatus = .empty
    @State private var isSearching = false
    @State private var errorMessage: String?

    private var selectedResult: DocumentationSearchResult? {
        results.first { $0.id == selectedResultID } ?? results.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            content
        }
        .task {
            status = await store.documentationIndexStatus()
        }
        .task(id: searchKey) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            await runSearch()
        }
        .animation(.smooth(duration: 0.2), value: results)
        .animation(.smooth(duration: 0.2), value: store.isIndexingDocumentation)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.title2)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Documentation Search")
                    .font(.title2.weight(.semibold))
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if store.isIndexingDocumentation {
                ProgressView()
                    .controlSize(.small)
            }

            Button(status.symbolCount == 0 ? "Build Index" : "Rebuild Index") {
                Task {
                    await store.rebuildDocumentationIndex()
                    status = await store.documentationIndexStatus()
                    await runSearch()
                }
            }
            .disabled(store.isIndexingDocumentation)

            Menu {
                Button("Rebuild Default Frameworks") {
                    Task {
                        await store.rebuildDocumentationIndex()
                        status = await store.documentationIndexStatus()
                        await runSearch()
                    }
                }
                Button("Index All Apple SDK Frameworks") {
                    Task {
                        await store.rebuildDocumentationIndex(includeAllFrameworks: true)
                        status = await store.documentationIndexStatus()
                        await runSearch()
                    }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(store.isIndexingDocumentation)
            .help("Rebuild documentation index")
        }
        .padding(18)
    }

    @ViewBuilder
    private var content: some View {
        if store.isIndexingDocumentation && results.isEmpty {
            indexingState
        } else if isSearching && results.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                resultsList
                    .frame(minWidth: 320, idealWidth: 380)

                detailPane
                    .frame(minWidth: 420)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            TextField("Search Apple documentation", text: $query)
                .textFieldStyle(.roundedBorder)

            Picker("Mode", selection: $mode) {
                Text("Symbols").tag(DocumentationSearchMode.symbols)
                Text("Docs").tag(DocumentationSearchMode.docs)
                Text("All").tag(DocumentationSearchMode.all)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            Picker("Platform", selection: $platformFilter) {
                Text("All").tag("all")
                ForEach(DocumentationPlatform.allCases) { platform in
                    Text(platform.displayName).tag(platform.rawValue)
                }
            }
            .frame(width: 150)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var resultsList: some View {
        List(selection: $selectedResultID) {
            if isSearching {
                ProgressView()
                    .padding()
            }

            ForEach(results) { result in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: result.type == .symbol ? "curlybraces" : "doc.text.magnifyingglass")
                            .foregroundStyle(.secondary)
                        Text(result.title)
                            .font(.headline)
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        Text(result.moduleOrFramework.isEmpty ? result.kind : "\(result.moduleOrFramework) • \(result.kind)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        ForEach(result.platforms) { platform in
                            Text(platform.displayName)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.75), in: .capsule)
                        }
                    }

                    if let snippet = result.snippet, !snippet.isEmpty {
                        Text(snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 4)
                .tag(result.id)
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let result = selectedResult {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(result.title)
                            .font(.title2.weight(.semibold))
                        Spacer()
                        Text(result.type == .symbol ? "Symbol" : "Docs")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    if !result.moduleOrFramework.isEmpty || !result.kind.isEmpty {
                        Text([result.moduleOrFramework, result.kind].filter { !$0.isEmpty }.joined(separator: " • "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if !result.platforms.isEmpty {
                        HStack {
                            ForEach(result.platforms) { platform in
                                Text(platform.displayName)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(.quaternary, in: .capsule)
                            }
                        }
                    }

                    if let declaration = result.declaration, !declaration.isEmpty {
                        Text(declaration)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: .rect(cornerRadius: 6))
                    }

                    if let snippet = result.snippet, !snippet.isEmpty {
                        Text(snippet)
                            .font(.body)
                            .textSelection(.enabled)
                    }

                    Text(result.identifier)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Select a Result", systemImage: "doc.text.magnifyingglass")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: "books.vertical")
        } description: {
            Text(emptyDescription)
        } actions: {
            if status.symbolCount == 0 && mode != .docs {
                Button("Build Index") {
                    Task {
                        await store.rebuildDocumentationIndex()
                        status = await store.documentationIndexStatus()
                        await runSearch()
                    }
                }
                .disabled(store.isIndexingDocumentation)
            }
        }
    }

    private var indexingState: some View {
        ContentUnavailableView {
            Label("Building Documentation Index", systemImage: "books.vertical")
        } description: {
            Text(store.documentationIndexProgressMessage ?? "Extracting Apple SDK symbol graphs in batches.")
        } actions: {
            ProgressView()
                .controlSize(.regular)
                .padding(.top, 4)
        }
    }

    private var selectedPlatform: DocumentationPlatform? {
        guard platformFilter != "all" else { return nil }
        return DocumentationPlatform(rawValue: platformFilter)
    }

    private var searchKey: String {
        "\(query)|\(mode.rawValue)|\(platformFilter)"
    }

    private var statusText: String {
        if let message = headerStatusMessage {
            return message
        }
        if status.symbolCount > 0 {
            return "\(status.symbolCount) symbols indexed" + (status.indexedSDKs.isEmpty ? "" : " from \(status.indexedSDKs.joined(separator: ", "))")
        }
        return "Build the local symbol index to search Apple SDK symbols."
    }

    private var headerStatusMessage: String? {
        if let progress = store.documentationIndexProgressMessage {
            return progress
        }
        if let message = nonEmptyStatusMessage {
            return message
        }
        if mode != .symbols, !status.semanticDocsAvailable, let semanticError = status.semanticDocsError {
            return semanticError
        }
        return nil
    }

    private var nonEmptyStatusMessage: String? {
        let value = store.documentationStatusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? errorMessage : value
    }

    private var emptyTitle: String {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Search Apple Documentation"
        }
        return "No Results"
    }

    private var emptyDescription: String {
        if status.symbolCount == 0 && mode != .docs {
            return "Build the index to search local SDK symbols."
        }
        if mode != .symbols, !status.semanticDocsAvailable {
            return status.semanticDocsError ?? "Semantic documentation search is unavailable."
        }
        return "Try a symbol, framework, or concept."
    }

    @MainActor
    private func runSearch() async {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            results = []
            selectedResultID = nil
            errorMessage = nil
            return
        }

        isSearching = true
        defer { isSearching = false }

        do {
            let response = try await store.searchDocumentation(DocumentationSearchRequest(
                query: normalized,
                mode: mode,
                platform: selectedPlatform,
                limit: 20
            ))
            status = response.indexStatus
            results = response.results
            selectedResultID = response.results.first?.id
            errorMessage = nil
        } catch {
            results = []
            selectedResultID = nil
            errorMessage = error.localizedDescription
        }
    }
}

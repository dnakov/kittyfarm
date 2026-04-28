import Foundation
import SQLite3

enum DocumentationIndexStoreError: LocalizedError {
    case openFailed(String)
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message), .sqlite(let message):
            message
        }
    }
}

final class DocumentationIndexStore: @unchecked Sendable {
    private let url: URL
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL = DocumentationIndexStore.defaultIndexURL()) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite open error"
            throw DocumentationIndexStoreError.openFailed(message)
        }
        try initializeSchema()
    }

    deinit {
        sqlite3_close(db)
    }

    static func defaultIndexURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appending(path: "KittyFarm", directoryHint: .isDirectory)
            .appending(path: "Documentation", directoryHint: .isDirectory)
            .appending(path: "index.sqlite")
    }

    func rebuild(
        symbols: [IndexedDocumentationSymbol],
        indexedSDKs: [String],
        failures: [DocumentationIndexFailure]
    ) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute("DELETE FROM symbols")
            try execute("DELETE FROM symbols_fts")
            try execute("DELETE FROM meta")
            try execute("DELETE FROM index_failures")

            var merged: [String: IndexedDocumentationSymbol] = [:]
            for symbol in symbols {
                if let existing = merged[symbol.preciseID] {
                    merged[symbol.preciseID] = existing.mergingPlatformsAndSDKs(from: symbol)
                } else {
                    merged[symbol.preciseID] = symbol
                }
            }

            for symbol in merged.values {
                try insert(symbol)
            }
            for failure in failures {
                try insert(failure)
            }

            try setMeta("indexed_at", value: ISO8601DateFormatter().string(from: Date()))
            try setMeta("indexed_sdks", value: jsonString(indexedSDKs.sorted()))
            try execute("INSERT INTO symbols_fts(symbols_fts) VALUES('rebuild')")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func status(semanticAvailable: Bool, semanticError: String?) throws -> DocumentationIndexStatus {
        DocumentationIndexStatus(
            symbolCount: try int("SELECT COUNT(*) FROM symbols"),
            indexedSDKs: try decodeMeta([String].self, key: "indexed_sdks") ?? [],
            indexedAt: try meta("indexed_at").flatMap { ISO8601DateFormatter().date(from: $0) },
            semanticDocsAvailable: semanticAvailable,
            semanticDocsError: semanticError,
            failedModules: try failures()
        )
    }

    func searchSymbols(query: String, platform: DocumentationPlatform?, limit: Int) throws -> [DocumentationSymbol] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let cappedLimit = max(1, min(limit, 25))
        let nameMatches = try searchByName(query: normalized, platform: platform, limit: cappedLimit)
        if !nameMatches.isEmpty {
            return nameMatches
        }
        return try searchFTS(query: normalized, platform: platform, limit: cappedLimit)
    }

    func symbol(preciseID: String) throws -> DocumentationSymbol? {
        let rows = try querySymbols(
            sql: """
            SELECT id, name, kind, kind_display, module, precise_id, path, declaration, doc_comment,
                   parent_id, availability, platforms_json, sdks_json, NULL
            FROM symbols
            WHERE precise_id = ?
            LIMIT 1
            """,
            bindings: [.text(preciseID)]
        )
        return rows.first
    }

    private func initializeSchema() throws {
        try execute("PRAGMA journal_mode=WAL")
        try execute("""
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS symbols (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            kind_display TEXT NOT NULL,
            module TEXT NOT NULL,
            precise_id TEXT NOT NULL UNIQUE,
            path TEXT NOT NULL,
            declaration TEXT NOT NULL,
            doc_comment TEXT NOT NULL,
            parent_id TEXT,
            availability TEXT NOT NULL,
            platforms_json TEXT NOT NULL,
            sdks_json TEXT NOT NULL
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_documentation_symbols_name ON symbols(name COLLATE NOCASE)")
        try execute("CREATE INDEX IF NOT EXISTS idx_documentation_symbols_module ON symbols(module)")
        try execute("CREATE INDEX IF NOT EXISTS idx_documentation_symbols_parent ON symbols(parent_id)")
        try execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS symbols_fts
        USING fts5(name, doc_comment, content='symbols', content_rowid='id')
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS index_failures (
            sdk TEXT NOT NULL,
            module TEXT NOT NULL,
            message TEXT NOT NULL,
            PRIMARY KEY (sdk, module)
        )
        """)
    }

    private func searchByName(query: String, platform: DocumentationPlatform?, limit: Int) throws -> [DocumentationSymbol] {
        var bindings: [Binding] = [.text("%\(query)%"), .text(query), .text("\(query)%")]
        var platformSQL = ""
        if let platform {
            platformSQL = "AND platforms_json LIKE ?"
            bindings.append(.text("%\"\(platform.rawValue)\"%"))
        }
        bindings.append(.int(limit))

        return try querySymbols(
            sql: """
            SELECT id, name, kind, kind_display, module, precise_id, path, declaration, doc_comment,
                   parent_id, availability, platforms_json, sdks_json, NULL
            FROM symbols
            WHERE name LIKE ? COLLATE NOCASE
            \(platformSQL)
            ORDER BY
                CASE WHEN name = ? COLLATE NOCASE THEN 0
                     WHEN name LIKE ? COLLATE NOCASE THEN 1
                     ELSE 2 END,
                CASE kind
                    WHEN 'swift.struct' THEN 0
                    WHEN 'swift.class' THEN 0
                    WHEN 'swift.protocol' THEN 0
                    WHEN 'swift.enum' THEN 0
                    ELSE 1
                END,
                length(name),
                module
            LIMIT ?
            """,
            bindings: bindings
        )
    }

    private func searchFTS(query: String, platform: DocumentationPlatform?, limit: Int) throws -> [DocumentationSymbol] {
        let ftsQuery = query
            .split(whereSeparator: \.isWhitespace)
            .map { $0.replacing("\"", with: "").replacing("'", with: "").replacing("*", with: "") }
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"*" }
            .joined(separator: " ")
        guard !ftsQuery.isEmpty else { return [] }

        var bindings: [Binding] = [.text(ftsQuery)]
        var platformSQL = ""
        if let platform {
            platformSQL = "AND s.platforms_json LIKE ?"
            bindings.append(.text("%\"\(platform.rawValue)\"%"))
        }
        bindings.append(.int(limit))

        return try querySymbols(
            sql: """
            SELECT s.id, s.name, s.kind, s.kind_display, s.module, s.precise_id, s.path, s.declaration,
                   s.doc_comment, s.parent_id, s.availability, s.platforms_json, s.sdks_json,
                   bm25(symbols_fts, 10.0, 1.0)
            FROM symbols_fts
            JOIN symbols s ON s.id = symbols_fts.rowid
            WHERE symbols_fts MATCH ?
            \(platformSQL)
            ORDER BY bm25(symbols_fts, 10.0, 1.0)
            LIMIT ?
            """,
            bindings: bindings
        )
    }

    private func insert(_ symbol: IndexedDocumentationSymbol) throws {
        try withStatement("""
        INSERT INTO symbols(
            name, kind, kind_display, module, precise_id, path, declaration, doc_comment,
            parent_id, availability, platforms_json, sdks_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """) { statement in
            try bind(.text(symbol.name), to: 1, in: statement)
            try bind(.text(symbol.kind), to: 2, in: statement)
            try bind(.text(symbol.kindDisplay), to: 3, in: statement)
            try bind(.text(symbol.module), to: 4, in: statement)
            try bind(.text(symbol.preciseID), to: 5, in: statement)
            try bind(.text(symbol.path), to: 6, in: statement)
            try bind(.text(symbol.declaration), to: 7, in: statement)
            try bind(.text(symbol.docComment), to: 8, in: statement)
            try bind(symbol.parentID.map(Binding.text) ?? .null, to: 9, in: statement)
            try bind(.text(symbol.availability), to: 10, in: statement)
            try bind(.text(jsonString(symbol.platforms.map(\.rawValue).sorted())), to: 11, in: statement)
            try bind(.text(jsonString(symbol.sdkNames.sorted())), to: 12, in: statement)
            try stepDone(statement)
        }
    }

    private func insert(_ failure: DocumentationIndexFailure) throws {
        try withStatement("INSERT OR REPLACE INTO index_failures(sdk, module, message) VALUES (?, ?, ?)") { statement in
            try bind(.text(failure.sdk), to: 1, in: statement)
            try bind(.text(failure.module), to: 2, in: statement)
            try bind(.text(failure.message), to: 3, in: statement)
            try stepDone(statement)
        }
    }

    private func setMeta(_ key: String, value: String) throws {
        try withStatement("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)") { statement in
            try bind(.text(key), to: 1, in: statement)
            try bind(.text(value), to: 2, in: statement)
            try stepDone(statement)
        }
    }

    private func failures() throws -> [DocumentationIndexFailure] {
        try withStatement("SELECT sdk, module, message FROM index_failures ORDER BY sdk, module") { statement in
            var result: [DocumentationIndexFailure] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(DocumentationIndexFailure(
                    sdk: columnText(statement, 0),
                    module: columnText(statement, 1),
                    message: columnText(statement, 2)
                ))
            }
            return result
        }
    }

    private func querySymbols(sql: String, bindings: [Binding]) throws -> [DocumentationSymbol] {
        try withStatement(sql) { statement in
            for (index, binding) in bindings.enumerated() {
                try bind(binding, to: Int32(index + 1), in: statement)
            }

            var symbols: [DocumentationSymbol] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let preciseID = columnText(statement, 5)
                symbols.append(DocumentationSymbol(
                    rowID: sqlite3_column_int64(statement, 0),
                    name: columnText(statement, 1),
                    kind: columnText(statement, 2),
                    kindDisplay: columnText(statement, 3),
                    module: columnText(statement, 4),
                    preciseID: preciseID,
                    path: columnText(statement, 6),
                    declaration: columnText(statement, 7),
                    docComment: columnText(statement, 8),
                    parentID: columnOptionalText(statement, 9),
                    availability: columnText(statement, 10),
                    platforms: decodeArray([String].self, from: columnText(statement, 11)).compactMap(DocumentationPlatform.init(rawValue:)),
                    sdkNames: decodeArray([String].self, from: columnText(statement, 12)),
                    memberCount: try memberCount(parentID: preciseID),
                    score: columnOptionalDouble(statement, 13)
                ))
            }
            return symbols
        }
    }

    private func memberCount(parentID: String) throws -> Int {
        try withStatement("SELECT COUNT(*) FROM symbols WHERE parent_id = ?") { statement in
            try bind(.text(parentID), to: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    private func int(_ sql: String) throws -> Int {
        try withStatement(sql) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    private func meta(_ key: String) throws -> String? {
        try withStatement("SELECT value FROM meta WHERE key = ?") { statement in
            try bind(.text(key), to: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return columnText(statement, 0)
        }
    }

    private func decodeMeta<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        guard let text = try meta(key), let data = text.data(using: .utf8) else { return nil }
        return try decoder.decode(type, from: data)
    }

    private func jsonString<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "null"
    }

    private func decodeArray<T: Decodable>(_ type: [T].Type, from text: String) -> [T] {
        guard let data = text.data(using: .utf8),
              let value = try? decoder.decode(type, from: data) else {
            return []
        }
        return value
    }

    private func execute(_ sql: String) throws {
        guard let db else { throw DocumentationIndexStoreError.sqlite("SQLite database is closed.") }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(error)
            throw DocumentationIndexStoreError.sqlite(message)
        }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard let db else { throw DocumentationIndexStoreError.sqlite("SQLite database is closed.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DocumentationIndexStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private enum Binding {
        case text(String)
        case int(Int)
        case null
    }

    private func bind(_ value: Binding, to index: Int32, in statement: OpaquePointer) throws {
        let result: Int32
        switch value {
        case .text(let text):
            result = sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        case .int(let int):
            result = sqlite3_bind_int(statement, index, Int32(int))
        case .null:
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else {
            throw DocumentationIndexStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DocumentationIndexStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    private func columnOptionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return columnText(statement, index)
    }

    private func columnOptionalDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }
}

private extension IndexedDocumentationSymbol {
    func mergingPlatformsAndSDKs(from other: IndexedDocumentationSymbol) -> IndexedDocumentationSymbol {
        IndexedDocumentationSymbol(
            name: name,
            kind: kind,
            kindDisplay: kindDisplay,
            module: module,
            preciseID: preciseID,
            path: path,
            declaration: declaration.isEmpty ? other.declaration : declaration,
            docComment: docComment.isEmpty ? other.docComment : docComment,
            parentID: parentID ?? other.parentID,
            availability: availability.isEmpty ? other.availability : availability,
            platforms: Array(Set(platforms + other.platforms)).sorted { $0.rawValue < $1.rawValue },
            sdkNames: Array(Set(sdkNames + other.sdkNames)).sorted()
        )
    }
}

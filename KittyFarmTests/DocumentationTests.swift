import Foundation
import XCTest
@testable import KittyFarm

final class DocumentationTests: XCTestCase {
    func testSymbolGraphParsingExtractsDeclarationDocCommentAndParent() throws {
        let symbols = try SymbolGraphParser.parse(
            data: Self.fixtureSymbolGraphData(),
            platform: .iOS,
            sdkName: "iphonesimulator"
        )

        XCTAssertEqual(symbols.count, 2)
        let navigationStack = try XCTUnwrap(symbols.first { $0.name == "NavigationStack" })
        XCTAssertEqual(navigationStack.kind, "swift.struct")
        XCTAssertEqual(navigationStack.kindDisplay, "Structure")
        XCTAssertEqual(navigationStack.module, "SwiftUI")
        XCTAssertEqual(navigationStack.declaration, "public struct NavigationStack<Root> where Root : View")
        XCTAssertEqual(navigationStack.docComment, "A view that displays a root view.\nUse navigation destinations.")
        XCTAssertEqual(navigationStack.platforms, [.iOS])
        XCTAssertEqual(navigationStack.sdkNames, ["iphonesimulator"])
        XCTAssertTrue(navigationStack.availability.contains("\"domain\":\"iOS\""))

        let member = try XCTUnwrap(symbols.first { $0.name == "init(root:)" })
        XCTAssertEqual(member.parentID, "s:SwiftUI.NavigationStack")
        XCTAssertFalse(symbols.contains { $0.name == "_PrivateSymbol" })
    }

    func testSQLiteFTSAndPreciseIDDedupingMergePlatforms() throws {
        let store = try DocumentationIndexStore(url: Self.temporaryIndexURL())
        try store.rebuild(
            symbols: [
                Self.symbol(platform: .macOS, sdk: "macosx"),
                Self.symbol(platform: .iOS, sdk: "iphonesimulator"),
                Self.symbol(
                    name: "SearchableDocCommentOnly",
                    preciseID: "s:SwiftUI.SearchableDocCommentOnly",
                    docComment: "This documentation mentions a unique routing phrase.",
                    platform: .watchOS,
                    sdk: "watchsimulator"
                ),
            ],
            indexedSDKs: ["macosx", "iphonesimulator", "watchsimulator"],
            failures: [
                DocumentationIndexFailure(sdk: "watchsimulator", module: "WidgetKit", message: "fixture failure"),
            ]
        )

        let status = try store.status(semanticAvailable: false, semanticError: "semantic unavailable")
        XCTAssertEqual(status.symbolCount, 2)
        XCTAssertEqual(status.indexedSDKs, ["iphonesimulator", "macosx", "watchsimulator"])
        XCTAssertEqual(status.failedModules.count, 1)

        let matches = try store.searchSymbols(query: "NavigationStack", platform: nil, limit: 10)
        let match = try XCTUnwrap(matches.first)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(match.preciseID, "s:SwiftUI.NavigationStack")
        XCTAssertEqual(Set(match.platforms), Set([.macOS, .iOS]))
        XCTAssertEqual(Set(match.sdkNames), Set(["macosx", "iphonesimulator"]))

        let iosMatches = try store.searchSymbols(query: "NavigationStack", platform: .iOS, limit: 10)
        XCTAssertEqual(iosMatches.count, 1)

        let watchMatches = try store.searchSymbols(query: "NavigationStack", platform: .watchOS, limit: 10)
        XCTAssertTrue(watchMatches.isEmpty)

        let ftsMatches = try store.searchSymbols(query: "unique routing", platform: .watchOS, limit: 10)
        XCTAssertEqual(ftsMatches.first?.name, "SearchableDocCommentOnly")
        XCTAssertNotNil(ftsMatches.first?.score)
    }

    func testSemanticDocsUnavailablePathReturnsStatusInsteadOfThrowing() async throws {
        let store = try DocumentationIndexStore(url: Self.temporaryIndexURL())
        let service = try DocumentationSearchService(
            store: store,
            semanticService: UnavailableSemanticDocumentationService()
        )

        let response = try await service.search(DocumentationSearchRequest(
            query: "swift testing",
            mode: .docs,
            limit: 5
        ))

        XCTAssertTrue(response.results.isEmpty)
        XCTAssertFalse(response.indexStatus.semanticDocsAvailable)
        XCTAssertEqual(response.indexStatus.semanticDocsError, "semantic fixture unavailable")
    }

    @MainActor
    func testMCPDocumentationToolSchemaAndOutputShape() async throws {
        let store = KittyFarmStore()
        let listBody = try Self.jsonData([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
        ])

        let listResponse = await LocalControlMCPHandler.respond(to: listBody, store: store)
        let listObject = try Self.jsonObject(listResponse.body)
        let result = try XCTUnwrap(listObject["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let docsTool = try XCTUnwrap(tools.first { $0["name"] as? String == "kittyfarm_search_documentation" })
        let schema = try XCTUnwrap(docsTool["inputSchema"] as? [String: Any])
        let required = try XCTUnwrap(schema["required"] as? [String])
        XCTAssertEqual(required, ["query"])

        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let mode = try XCTUnwrap(properties["mode"] as? [String: Any])
        XCTAssertEqual(mode["enum"] as? [String], ["symbols", "docs", "all"])
        let platform = try XCTUnwrap(properties["platform"] as? [String: Any])
        XCTAssertEqual(platform["enum"] as? [String], ["macos", "ios", "watchos", "all"])

        let callBody = try Self.jsonData([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": [
                "name": "kittyfarm_search_documentation",
                "arguments": [
                    "query": "NavigationStack",
                    "mode": "symbols",
                    "platform": "all",
                    "limit": 3,
                ],
            ],
        ])
        let callResponse = await LocalControlMCPHandler.respond(to: callBody, store: store)
        let callObject = try Self.jsonObject(callResponse.body)
        let callResult = try XCTUnwrap(callObject["result"] as? [String: Any])
        let content = try XCTUnwrap(callResult["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DocumentationSearchResponse.self, from: Data(text.utf8))

        XCTAssertLessThanOrEqual(decoded.results.count, 3)
        XCTAssertNotNil(decoded.indexStatus)
    }

    private static func temporaryIndexURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "KittyFarmDocumentationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "index.sqlite")
    }

    private static func symbol(
        name: String = "NavigationStack",
        preciseID: String = "s:SwiftUI.NavigationStack",
        docComment: String = "A view that displays a root view.",
        platform: DocumentationPlatform,
        sdk: String
    ) -> IndexedDocumentationSymbol {
        IndexedDocumentationSymbol(
            name: name,
            kind: "swift.struct",
            kindDisplay: "Structure",
            module: "SwiftUI",
            preciseID: preciseID,
            path: "SwiftUI/\(name)",
            declaration: "public struct \(name)<Root> where Root : View",
            docComment: docComment,
            parentID: nil,
            availability: "",
            platforms: [platform],
            sdkNames: [sdk]
        )
    }

    private static func jsonData(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func fixtureSymbolGraphData() -> Data {
        Data(
            """
            {
              "module": { "name": "SwiftUI" },
              "symbols": [
                {
                  "identifier": { "precise": "s:SwiftUI.NavigationStack" },
                  "names": { "title": "NavigationStack" },
                  "kind": { "identifier": "swift.struct", "displayName": "Structure" },
                  "pathComponents": ["SwiftUI", "NavigationStack"],
                  "declarationFragments": [
                    { "spelling": "public " },
                    { "spelling": "struct " },
                    { "spelling": "NavigationStack" },
                    { "spelling": "<Root> where Root : View" }
                  ],
                  "docComment": {
                    "lines": [
                      { "text": "A view that displays a root view." },
                      { "text": "Use navigation destinations." }
                    ]
                  },
                  "accessLevel": "public",
                  "spi": false,
                  "availability": [
                    { "domain": "iOS", "introduced": { "major": 16, "minor": 0 } }
                  ]
                },
                {
                  "identifier": { "precise": "s:SwiftUI.NavigationStack.init" },
                  "names": { "title": "init(root:)" },
                  "kind": { "identifier": "swift.init", "displayName": "Initializer" },
                  "pathComponents": ["SwiftUI", "NavigationStack", "init(root:)"],
                  "declarationFragments": [
                    { "spelling": "public init(root: () -> Root)" }
                  ],
                  "accessLevel": "public",
                  "spi": false
                },
                {
                  "identifier": { "precise": "s:SwiftUI.Private" },
                  "names": { "title": "_PrivateSymbol" },
                  "kind": { "identifier": "swift.struct", "displayName": "Structure" },
                  "accessLevel": "private",
                  "spi": false
                }
              ],
              "relationships": [
                {
                  "kind": "memberOf",
                  "source": "s:SwiftUI.NavigationStack.init",
                  "target": "s:SwiftUI.NavigationStack",
                  "targetFallback": "NavigationStack"
                },
                {
                  "kind": "memberOf",
                  "source": "s:SwiftUI.NavigationStack.init",
                  "target": "s:SwiftUI.NavigationStack",
                  "targetFallback": "NavigationStack"
                }
              ]
            }
            """.utf8
        )
    }
}

private struct UnavailableSemanticDocumentationService: SemanticDocumentationServicing {
    func availability() -> SemanticDocumentationService.Availability {
        SemanticDocumentationService.Availability(
            isAvailable: false,
            errorMessage: "semantic fixture unavailable"
        )
    }

    func search(
        query: String,
        frameworks: [String],
        kinds: [String],
        limit: Int,
        omitContent: Bool
    ) throws -> [SemanticDocumentationResult] {
        throw SemanticDocumentationError.unavailable("semantic fixture unavailable")
    }

    func get(identifier: String) throws -> SemanticDocumentationResult {
        throw SemanticDocumentationError.unavailable("semantic fixture unavailable")
    }
}

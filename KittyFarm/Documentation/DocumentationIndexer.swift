import Foundation

struct DocumentationIndexProgress: Sendable {
    let message: String
    let completed: Int
    let total: Int
}

struct DocumentationIndexBuildResult: Sendable {
    let symbolCount: Int
    let indexedSDKs: [String]
    let failures: [DocumentationIndexFailure]
}

actor DocumentationIndexer {
    typealias ProgressHandler = @Sendable (DocumentationIndexProgress) async -> Void

    static let defaultModules = [
        "Swift", "Foundation", "SwiftUI", "SwiftUICore", "UIKit", "AppKit",
        "Combine", "Observation", "SwiftData", "CoreData",
        "CoreGraphics", "CoreImage", "CoreText", "CoreLocation",
        "MapKit", "AVFoundation", "AVKit",
        "StoreKit", "CloudKit", "AuthenticationServices",
        "Network", "WebKit",
        "CoreML", "Vision", "NaturalLanguage",
        "UserNotifications", "AppIntents", "WidgetKit",
        "Metal", "SceneKit", "SpriteKit", "ARKit",
    ]

    private let store: DocumentationIndexStore
    private let fileManager: FileManager
    private let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")

    init(store: DocumentationIndexStore, fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
    }

    func rebuildDefaultIndex(progress: ProgressHandler? = nil) async throws -> DocumentationIndexBuildResult {
        try await rebuildIndex(modules: Self.defaultModules, includeAllFrameworks: false, progress: progress)
    }

    func rebuildAllFrameworkIndex(progress: ProgressHandler? = nil) async throws -> DocumentationIndexBuildResult {
        try await rebuildIndex(modules: [], includeAllFrameworks: true, progress: progress)
    }

    func rebuildIndex(
        modules requestedModules: [String],
        includeAllFrameworks: Bool,
        progress: ProgressHandler? = nil
    ) async throws -> DocumentationIndexBuildResult {
        let sdks = try await detectSDKs()
        var modulesBySDK: [(SDKTarget, [String])] = []
        for sdk in sdks {
            let modules = includeAllFrameworks ? try await listFrameworkModules(sdk: sdk) : requestedModules
            modulesBySDK.append((sdk, modules.filter { sdk.supports(module: $0) }))
        }
        let total = modulesBySDK.reduce(0) { $0 + $1.1.count }
        var completed = 0
        var symbols: [IndexedDocumentationSymbol] = []
        var failures: [DocumentationIndexFailure] = []

        for (sdk, modules) in modulesBySDK {
            let outputDirectory = try temporaryDirectory(prefix: "kittyfarm-symbolgraphs-\(sdk.name)")
            defer { try? fileManager.removeItem(at: outputDirectory) }

            for module in modules {
                try Task.checkCancellation()
                await progress?(DocumentationIndexProgress(
                    message: "Indexing \(module) from \(sdk.displayName)",
                    completed: completed,
                    total: total
                ))

                do {
                    let files = try await extract(module: module, sdk: sdk, outputDirectory: outputDirectory)
                    for file in files {
                        symbols += try SymbolGraphParser.parse(fileURL: file, platform: sdk.platform, sdkName: sdk.name)
                    }
                } catch {
                    failures.append(DocumentationIndexFailure(
                        sdk: sdk.name,
                        module: module,
                        message: error.localizedDescription
                    ))
                }
                completed += 1
            }
        }

        let indexedSDKs = sdks.map(\.name)
        try store.rebuild(symbols: symbols, indexedSDKs: indexedSDKs, failures: failures)
        await progress?(DocumentationIndexProgress(
            message: "Indexed \(symbols.count) symbols",
            completed: total,
            total: total
        ))
        return DocumentationIndexBuildResult(symbolCount: symbols.count, indexedSDKs: indexedSDKs, failures: failures)
    }

    private func detectSDKs() async throws -> [SDKTarget] {
        var targets: [SDKTarget] = []
        for sdk in SDKTarget.defaultTargets {
            do {
                let path = try await sdkPath(for: sdk.name)
                targets.append(sdk.withPath(path))
            } catch {
                // Missing optional SDKs should not prevent indexing available Apple SDKs.
            }
        }
        if targets.isEmpty {
            throw LocalControlStoreError.invalidRequest("No Apple SDKs were found through xcrun.")
        }
        return targets
    }

    private func sdkPath(for name: String) async throws -> String {
        let result = try await ProcessRunner.run(ProcessRunner.Command(
            executableURL: xcrunURL,
            arguments: ["--sdk", name, "--show-sdk-path"]
        ))
        try result.requireSuccess("Resolve \(name) SDK")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func listFrameworkModules(sdk: SDKTarget) async throws -> [String] {
        let frameworksURL = URL(fileURLWithPath: sdk.path)
            .appending(path: "System", directoryHint: .isDirectory)
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Frameworks", directoryHint: .isDirectory)
        let entries = try fileManager.contentsOfDirectory(at: frameworksURL, includingPropertiesForKeys: nil)
        return entries
            .filter { $0.pathExtension == "framework" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    private func extract(module: String, sdk: SDKTarget, outputDirectory: URL) async throws -> [URL] {
        let before = try symbolGraphFiles(in: outputDirectory)
        let result = try await ProcessRunner.run(ProcessRunner.Command(
            executableURL: xcrunURL,
            arguments: [
                "swift", "symbolgraph-extract",
                "-module-name", module,
                "-sdk", sdk.path,
                "-target", sdk.targetTriple,
                "-output-dir", outputDirectory.path,
                "-minimum-access-level", "public",
            ]
        ))
        try result.requireSuccess("Extract \(module) symbol graph for \(sdk.displayName)")
        let after = try symbolGraphFiles(in: outputDirectory)
        return Array(Set(after).subtracting(before)).sorted { $0.path < $1.path }
    }

    private func symbolGraphFiles(in directory: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".symbols.json") }
    }

    private func temporaryDirectory(prefix: String) throws -> URL {
        let url = fileManager.temporaryDirectory.appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct SDKTarget: Sendable {
    let name: String
    let displayName: String
    let platform: DocumentationPlatform
    let targetTriple: String
    let path: String
    let excludedModules: Set<String>

    static let defaultTargets = [
        SDKTarget(name: "macosx", displayName: "macOS", platform: .macOS, targetTriple: "arm64-apple-macos26.0", path: "", excludedModules: ["UIKit"]),
        SDKTarget(name: "iphonesimulator", displayName: "iPhone Simulator", platform: .iOS, targetTriple: "arm64-apple-ios26.0-simulator", path: "", excludedModules: ["AppKit"]),
        SDKTarget(name: "watchsimulator", displayName: "Watch Simulator", platform: .watchOS, targetTriple: "arm64-apple-watchos26.0-simulator", path: "", excludedModules: ["AppKit"]),
    ]

    func withPath(_ path: String) -> SDKTarget {
        SDKTarget(
            name: name,
            displayName: displayName,
            platform: platform,
            targetTriple: targetTriple,
            path: path,
            excludedModules: excludedModules
        )
    }

    func supports(module: String) -> Bool {
        !excludedModules.contains(module)
    }
}

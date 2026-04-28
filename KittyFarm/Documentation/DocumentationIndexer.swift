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

private struct DocumentationExtractionJob: Sendable {
    let sdk: SDKTarget
    let module: String
    let outputDirectory: URL
}

private struct DocumentationExtractionResult: Sendable {
    let sdk: SDKTarget
    let module: String
    let outputDirectory: URL
    let symbols: [IndexedDocumentationSymbol]
    let failure: DocumentationIndexFailure?
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
        var jobs: [DocumentationExtractionJob] = []

        for (sdk, modules) in modulesBySDK {
            for module in modules {
                jobs.append(DocumentationExtractionJob(
                    sdk: sdk,
                    module: module,
                    outputDirectory: try temporaryDirectory(prefix: "kittyfarm-symbolgraphs-\(sdk.name)-\(module)")
                ))
            }
        }
        defer {
            for job in jobs {
                try? fileManager.removeItem(at: job.outputDirectory)
            }
        }

        let batchSize = Self.batchSize
        for batch in jobs.chunked(size: batchSize) {
            try Task.checkCancellation()
            let moduleList = batch.map { "\($0.module) (\($0.sdk.displayName))" }.joined(separator: ", ")
            await progress?(DocumentationIndexProgress(
                message: "Indexing \(batch.count) modules: \(moduleList)",
                completed: completed,
                total: total
            ))

            await withTaskGroup(of: DocumentationExtractionResult.self) { group in
                for job in batch {
                    group.addTask {
                        await Self.extract(job)
                    }
                }

                for await result in group {
                    symbols += result.symbols
                    if let failure = result.failure {
                        failures.append(failure)
                    }
                    completed += 1
                    await progress?(DocumentationIndexProgress(
                        message: result.failure == nil
                            ? "Indexed \(result.module) from \(result.sdk.displayName)"
                            : "Skipped \(result.module) from \(result.sdk.displayName)",
                        completed: completed,
                        total: total
                    ))
                }
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

    private static var batchSize: Int {
        max(2, min(6, ProcessInfo.processInfo.activeProcessorCount / 2))
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

    private nonisolated static func extract(_ job: DocumentationExtractionJob) async -> DocumentationExtractionResult {
        do {
            try Task.checkCancellation()
            let files = try await extract(module: job.module, sdk: job.sdk, outputDirectory: job.outputDirectory)
            var symbols: [IndexedDocumentationSymbol] = []
            for file in files {
                symbols += try SymbolGraphParser.parse(fileURL: file, platform: job.sdk.platform, sdkName: job.sdk.name)
            }
            return DocumentationExtractionResult(
                sdk: job.sdk,
                module: job.module,
                outputDirectory: job.outputDirectory,
                symbols: symbols,
                failure: nil
            )
        } catch {
            return DocumentationExtractionResult(
                sdk: job.sdk,
                module: job.module,
                outputDirectory: job.outputDirectory,
                symbols: [],
                failure: DocumentationIndexFailure(
                    sdk: job.sdk.name,
                    module: job.module,
                    message: error.localizedDescription
                )
            )
        }
    }

    private nonisolated static func extract(module: String, sdk: SDKTarget, outputDirectory: URL) async throws -> [URL] {
        let before = try symbolGraphFiles(in: outputDirectory)
        let result = try await ProcessRunner.run(ProcessRunner.Command(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
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

    private nonisolated static func symbolGraphFiles(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".symbols.json") }
    }

    private func temporaryDirectory(prefix: String) throws -> URL {
        let url = fileManager.temporaryDirectory.appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private extension Array {
    func chunked(size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var result: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(Array(self[index..<next]))
            index = next
        }
        return result
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

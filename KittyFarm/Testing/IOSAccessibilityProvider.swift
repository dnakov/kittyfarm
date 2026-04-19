import Foundation

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

actor IOSAccessibilityProvider: AccessibilityTreeProvider {
    private let udid: String
    private let screenWidth: Double
    private let screenHeight: Double
    private let bundleIdentifier: String?
    private var probePort: UInt16?
    private var probeProcess: Task<ProcessRunner.Result, Error>?

    private static let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    private static let xcodebuildURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")

    init(udid: String, screenWidth: Double, screenHeight: Double, bundleIdentifier: String? = nil) {
        self.udid = udid
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.bundleIdentifier = bundleIdentifier
    }

    nonisolated func fetchTree(bundleIdentifier: String?) async throws -> [AccessibilityElement] {
        let port = try await ensureRunning()
        let storedBID = await self.bundleIdentifier
        let bid = bundleIdentifier ?? storedBID
        let bundleQuery = bid.map { "&bundleId=\($0)" } ?? ""
        let url = URL(string: "http://localhost:\(port)/tree?_=\(Int(Date().timeIntervalSince1970))\(bundleQuery)")!
        let (data, _) = try await URLSession.shared.data(from: url)

        let root = try JSONDecoder().decode(AccessibilityElement.self, from: data)
        return root.children.isEmpty ? [root] : root.children
    }

    nonisolated func screenSize() async throws -> (width: Double, height: Double) {
        let w = await screenWidth
        let h = await screenHeight
        return (w, h)
    }

    func ensureRunning() async throws -> UInt16 {
        if let port = probePort, await isAlive(port: port) {
            return port
        }

        probeProcess?.cancel()
        probeProcess = nil
        probePort = nil

        // Note: xcodebuild test-without-building handles installation from the .xctestrun,
        // so we don't need a separate `simctl install` step.
        let port = try await launch()
        probePort = port
        return port
    }

    func stop() {
        probeProcess?.cancel()
        probeProcess = nil
        probePort = nil
    }

    // MARK: - Embedded probe products

    private static func probeResourceDir() throws -> URL {
        guard let resourceURL = Bundle.main.resourceURL else {
            throw IOSAccessibilityProviderError.probeNotEmbedded
        }
        let probeDir = resourceURL.appending(path: "KittyProbe")
        guard FileManager.default.fileExists(atPath: probeDir.path) else {
            throw IOSAccessibilityProviderError.probeNotEmbedded
        }
        return probeDir
    }

    private func install() async throws {
        let probeDir = try Self.probeResourceDir()
        let fm = FileManager.default
        let productsDir = probeDir.appending(path: "Debug-iphonesimulator")

        let hostApp = productsDir.appending(path: "KittyProbeApp.app")
        guard fm.fileExists(atPath: hostApp.path) else {
            throw IOSAccessibilityProviderError.probeNotEmbedded
        }

        let contents = try fm.contentsOfDirectory(atPath: productsDir.path)
        guard let runnerName = contents.first(where: { $0.hasSuffix("-Runner.app") }) else {
            throw IOSAccessibilityProviderError.probeNotEmbedded
        }
        let runnerApp = productsDir.appending(path: runnerName)

        try await runSimctl(["install", udid, hostApp.path])
        try await runSimctl(["install", udid, runnerApp.path])
    }

    private func launch() async throws -> UInt16 {
        let probeDir = try Self.probeResourceDir()
        let fm = FileManager.default

        let contents = try fm.contentsOfDirectory(atPath: probeDir.path)
        guard let xctestrunName = contents.first(where: { $0.hasSuffix(".xctestrun") }) else {
            throw IOSAccessibilityProviderError.probeNotEmbedded
        }
        let xctestrunPath = probeDir.appending(path: xctestrunName).path

        let collector = OutputCollector()

        let processTask = Task.detached { [udid] in
            try await ProcessRunner.run(
                .init(
                    executableURL: Self.xcodebuildURL,
                    arguments: [
                        "test-without-building",
                        "-xctestrun", xctestrunPath,
                        "-destination", "platform=iOS Simulator,id=\(udid)"
                    ]
                ),
                onOutput: { event in
                    collector.append(event.text)
                }
            )
        }
        probeProcess = processTask

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)

            for line in collector.snapshot() {
                if line.contains("[KittyProbe] port=") {
                    let portStr = line.components(separatedBy: "port=").last?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if let parsedPort = UInt16(portStr) {
                        return parsedPort
                    }
                }
            }
        }

        // Fallback: use hash-based port and hope the probe started
        return assignPort()
    }

    private func isAlive(port: UInt16) async -> Bool {
        let url = URL(string: "http://localhost:\(port)/ping")!
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let httpResponse = response as? HTTPURLResponse
            return httpResponse?.statusCode == 200 && String(decoding: data, as: UTF8.self) == "ok"
        } catch {
            return false
        }
    }

    private func assignPort() -> UInt16 {
        var hasher = Hasher()
        hasher.combine(udid)
        let hash = hasher.finalize()
        return UInt16(19876 + (abs(hash) % 10000))
    }

    private func runSimctl(_ arguments: [String]) async throws {
        let result = try await ProcessRunner.run(.init(
            executableURL: Self.xcrunURL,
            arguments: ["simctl"] + arguments
        ))
        try result.requireSuccess("simctl \(arguments.first ?? "")")
    }
}

enum IOSAccessibilityProviderError: LocalizedError {
    case probeNotEmbedded
    case probeStartTimeout

    var errorDescription: String? {
        switch self {
        case .probeNotEmbedded:
            return "KittyProbe is not embedded in the app bundle. Rebuild KittyFarm to embed it."
        case .probeStartTimeout:
            return "KittyProbe failed to start within 30 seconds."
        }
    }
}

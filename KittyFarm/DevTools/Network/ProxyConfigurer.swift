import Foundation

actor ProxyConfigurer {
    static let shared = ProxyConfigurer()

    private struct PriorProxyState: Codable, Sendable {
        var httpHost: String?
        var httpPort: Int?
        var httpsHost: String?
        var httpsPort: Int?
    }

    private static let domain = "com.apple.NetworkServiceSetting"
    private static let httpHostKey = "HTTPProxy"
    private static let httpPortKey = "HTTPPort"
    private static let httpsHostKey = "HTTPSProxy"
    private static let httpsPortKey = "HTTPSPort"

    func enable(udid: String, host: String, port: Int) async throws {
        let prior = await readCurrent(udid: udid)
        try writeState(prior, udid: udid)
        try await writeDefault(udid: udid, key: Self.httpHostKey, value: host)
        try await writeDefault(udid: udid, key: Self.httpPortKey, value: "\(port)")
        try await writeDefault(udid: udid, key: Self.httpsHostKey, value: host)
        try await writeDefault(udid: udid, key: Self.httpsPortKey, value: "\(port)")
    }

    func disable(udid: String) async throws {
        let state = readState(udid: udid)
        try await restore(udid: udid, state: state)
        deleteStateFile(udid: udid)
    }

    func cleanupStale() async {
        let fileManager = FileManager.default
        let dir = Self.stateDirectory
        guard let entries = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return }
        for name in entries where name.hasSuffix(".json") {
            let udid = (name as NSString).deletingPathExtension
            guard !udid.isEmpty else { continue }
            let state = readState(udid: udid)
            do {
                try await restore(udid: udid, state: state)
            } catch {
                print("ProxyConfigurer.cleanupStale restore failed for \(udid): \(error.localizedDescription)")
            }
            deleteStateFile(udid: udid)
        }
    }

    private func restore(udid: String, state: PriorProxyState?) async throws {
        let state = state ?? PriorProxyState()

        try await restoreKey(udid: udid, key: Self.httpHostKey, value: state.httpHost)
        if let port = state.httpPort {
            try await writeDefault(udid: udid, key: Self.httpPortKey, value: "\(port)")
        } else {
            try await deleteDefault(udid: udid, key: Self.httpPortKey)
        }
        try await restoreKey(udid: udid, key: Self.httpsHostKey, value: state.httpsHost)
        if let port = state.httpsPort {
            try await writeDefault(udid: udid, key: Self.httpsPortKey, value: "\(port)")
        } else {
            try await deleteDefault(udid: udid, key: Self.httpsPortKey)
        }
    }

    private func restoreKey(udid: String, key: String, value: String?) async throws {
        if let value, !value.isEmpty {
            try await writeDefault(udid: udid, key: key, value: value)
        } else {
            try await deleteDefault(udid: udid, key: key)
        }
    }

    private func readCurrent(udid: String) async -> PriorProxyState {
        var state = PriorProxyState()
        state.httpHost = try? await readDefault(udid: udid, key: Self.httpHostKey)
        state.httpPort = (try? await readDefault(udid: udid, key: Self.httpPortKey)).flatMap { Int($0) }
        state.httpsHost = try? await readDefault(udid: udid, key: Self.httpsHostKey)
        state.httpsPort = (try? await readDefault(udid: udid, key: Self.httpsPortKey)).flatMap { Int($0) }
        return state
    }

    private func readDefault(udid: String, key: String) async throws -> String? {
        let result = try await ProcessRunner.run(
            XcrunUtils.simctl(["spawn", udid, "defaults", "read", Self.domain, key])
        )
        guard result.terminationStatus == 0 else { return nil }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func writeDefault(udid: String, key: String, value: String) async throws {
        _ = try await ProcessRunner.run(
            XcrunUtils.simctl(["spawn", udid, "defaults", "write", Self.domain, key, value])
        )
    }

    private func deleteDefault(udid: String, key: String) async throws {
        _ = try await ProcessRunner.run(
            XcrunUtils.simctl(["spawn", udid, "defaults", "delete", Self.domain, key])
        )
    }

    // MARK: - State persistence

    private static var stateDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base.appending(path: "KittyFarm/prior-proxy")
    }

    private static func stateURL(udid: String) -> URL {
        stateDirectory.appending(path: "\(udid).json")
    }

    private func writeState(_ state: PriorProxyState, udid: String) throws {
        let dir = Self.stateDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: Self.stateURL(udid: udid), options: .atomic)
    }

    private func readState(udid: String) -> PriorProxyState? {
        guard let data = try? Data(contentsOf: Self.stateURL(udid: udid)) else { return nil }
        return try? JSONDecoder().decode(PriorProxyState.self, from: data)
    }

    private func deleteStateFile(udid: String) {
        try? FileManager.default.removeItem(at: Self.stateURL(udid: udid))
    }
}

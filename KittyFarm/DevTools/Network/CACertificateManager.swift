import Foundation

actor CACertificateManager {
    static let shared = CACertificateManager()

    private var trusted: Set<String>?

    func ensureInstalled(udid: String) async throws {
        if try loadTrusted().contains(udid) { return }

        let pemURL = try await resolveOrGenerateRootCert()
        let result = try await ProcessRunner.run(
            XcrunUtils.simctl(["keychain", udid, "add-root-cert", pemURL.path])
        )
        guard result.terminationStatus == 0 else {
            throw NetworkMonitorError.caInstallFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        var set = try loadTrusted()
        set.insert(udid)
        try saveTrusted(set)
    }

    private func resolveOrGenerateRootCert() async throws -> URL {
        let pemURL = Self.pemURL
        if FileManager.default.fileExists(atPath: pemURL.path) {
            return pemURL
        }

        // Trigger CA generation by running mitmdump once with --version.
        guard let mitmdumpURL = Self.findMitmdump() else {
            throw NetworkMonitorError.mitmproxyMissing
        }
        _ = try? await ProcessRunner.run(
            ProcessRunner.Command(executableURL: mitmdumpURL, arguments: ["--version"])
        )

        // Run a short listen to ensure confdir + cert are produced, then kill.
        if !FileManager.default.fileExists(atPath: pemURL.path) {
            try await forceGenerateCert(mitmdumpURL: mitmdumpURL)
        }

        guard FileManager.default.fileExists(atPath: pemURL.path) else {
            throw NetworkMonitorError.caGenerationFailed
        }
        return pemURL
    }

    private func forceGenerateCert(mitmdumpURL: URL) async throws {
        let process = Process()
        process.executableURL = mitmdumpURL
        process.arguments = ["--listen-port", "0", "--set", "confdir=~/.mitmproxy"]
        let devNull = FileHandle(forWritingAtPath: "/dev/null")
        if let devNull {
            process.standardOutput = devNull
            process.standardError = devNull
        }
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            if FileManager.default.fileExists(atPath: Self.pemURL.path) { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if process.isRunning {
            process.terminate()
        }
    }

    // MARK: - Paths

    private static var pemURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: ".mitmproxy/mitmproxy-ca-cert.pem")
    }

    static func findMitmdump() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/mitmdump",
            "/usr/local/bin/mitmdump",
            "/opt/local/bin/mitmdump",
            "/usr/bin/mitmdump"
        ]
        let fileManager = FileManager.default
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Fall back to `/usr/bin/which` in case PATH has a less common install.
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["mitmdump"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do { try which.run() } catch { return nil }
        which.waitUntilExit()
        guard which.terminationStatus == 0 else { return nil }
        let data = try? pipe.fileHandleForReading.readToEnd()
        let path = String(decoding: data ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, fileManager.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Trusted UDIDs persistence

    private static var trustedURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base.appending(path: "KittyFarm/trusted-udids.json")
    }

    private func loadTrusted() throws -> Set<String> {
        if let trusted { return trusted }
        let url = Self.trustedURL
        guard let data = try? Data(contentsOf: url) else {
            self.trusted = []
            return []
        }
        let list = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        let set = Set(list)
        self.trusted = set
        return set
    }

    private func saveTrusted(_ set: Set<String>) throws {
        let url = Self.trustedURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(set.sorted())
        try data.write(to: url, options: .atomic)
        self.trusted = set
    }
}

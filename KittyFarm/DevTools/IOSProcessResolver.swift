import Foundation

enum IOSProcessResolver {
    static func resolvePID(udid: String, bundleID: String) async throws -> pid_t? {
        if let pid = try await resolvePIDViaLaunchctl(udid: udid, bundleID: bundleID) {
            return pid
        }
        return try await resolvePIDViaPgrep(udid: udid, bundleID: bundleID)
    }

    private static func resolvePIDViaLaunchctl(udid: String, bundleID: String) async throws -> pid_t? {
        let result = try await ProcessRunner.run(
            XcrunUtils.simctl(["spawn", udid, "launchctl", "list"])
        )
        guard result.terminationStatus == 0 else { return nil }

        let needle = "UIKitApplication:\(bundleID)"
        for line in result.stdout.split(separator: "\n") {
            guard line.contains(needle) else { continue }
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard let first = parts.first else { continue }
            if first == "-" { return nil }
            if let pid = pid_t(first) { return pid }
        }
        return nil
    }

    private static func resolvePIDViaPgrep(udid: String, bundleID: String) async throws -> pid_t? {
        let result = try await ProcessRunner.run(
            XcrunUtils.simctl(["spawn", udid, "pgrep", "-f", bundleID])
        )
        guard result.terminationStatus == 0 else { return nil }

        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstLine = trimmed.split(separator: "\n").first else { return nil }
        return pid_t(firstLine.trimmingCharacters(in: .whitespaces))
    }
}

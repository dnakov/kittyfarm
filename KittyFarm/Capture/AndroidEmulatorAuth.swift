import Foundation
import GRPCCore

/// Builds the `authorization: Bearer <token>` metadata that newer Android
/// emulators (and any started by Android Studio) require on every gRPC call —
/// otherwise they reject with "Missing the 'authorization' header with security
/// credentials" or "The token `Bearer …` is invalid".
///
/// Each running emulator instance gets its own token, written to
/// `~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini` under the
/// `grpc.token` key, alongside `grpc.port`. We match by port. If no
/// per-instance token is found we fall back to the legacy global token at
/// `~/.emulator_console_auth_token`.
enum AndroidEmulatorAuth {
    private static let cache = Cache()

    static func metadata(forGRPCPort port: Int) -> GRPCCore.Metadata {
        cache.metadata(forPort: port)
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var byPort: [Int: GRPCCore.Metadata] = [:]

        func metadata(forPort port: Int) -> GRPCCore.Metadata {
            lock.lock()
            defer { lock.unlock() }
            if let existing = byPort[port] {
                return existing
            }
            let metadata = Self.buildMetadata(forPort: port)
            byPort[port] = metadata
            return metadata
        }

        private static func buildMetadata(forPort port: Int) -> GRPCCore.Metadata {
            var metadata = GRPCCore.Metadata()
            if let token = lookupToken(forPort: port) {
                metadata.addString("Bearer \(token)", forKey: "authorization")
            }
            return metadata
        }

        private static func lookupToken(forPort port: Int) -> String? {
            if let token = perInstanceToken(forPort: port) {
                return token
            }
            return globalToken()
        }

        private static func perInstanceToken(forPort port: Int) -> String? {
            let runningDir = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Caches/TemporaryItems/avd/running")
            guard
                let entries = try? FileManager.default.contentsOfDirectory(
                    at: runningDir,
                    includingPropertiesForKeys: nil
                )
            else {
                return nil
            }

            let portValue = String(port)
            for url in entries where url.pathExtension == "ini" {
                guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                    continue
                }
                let fields = parseIni(contents)
                guard fields["grpc.port"] == portValue else {
                    continue
                }
                if let token = fields["grpc.token"], !token.isEmpty {
                    return token
                }
            }
            return nil
        }

        private static func globalToken() -> String? {
            let url = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".emulator_console_auth_token")
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
                return nil
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private static func parseIni(_ contents: String) -> [String: String] {
            var result: [String: String] = [:]
            for rawLine in contents.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard let equalsIndex = line.firstIndex(of: "=") else {
                    continue
                }
                let key = line[..<equalsIndex].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
                result[key] = value
            }
            return result
        }
    }
}

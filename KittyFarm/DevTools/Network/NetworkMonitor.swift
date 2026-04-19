import Foundation

actor NetworkMonitor {
    static let shared = NetworkMonitor()

    typealias RequestHandler = @Sendable (NetworkRequest) -> Void

    private struct Session {
        let udid: String
        let process: Process
        let stdoutTask: Task<Void, Never>
        let stderrTask: Task<Void, Never>
        let port: Int
        let addonURL: URL
    }

    private var sessions: [String: Session] = [:]

    func start(
        deviceID: String,
        udid: String,
        onRequest: @escaping RequestHandler
    ) async throws {
        if sessions[deviceID] != nil {
            await stop(deviceID: deviceID)
        }

        guard let mitmdumpURL = CACertificateManager.findMitmdump() else {
            throw NetworkMonitorError.mitmproxyMissing
        }

        try await CACertificateManager.shared.ensureInstalled(udid: udid)

        let addonURL = try Self.stagedAddonURL()
        let port = Self.pickPort(for: udid)

        try await ProxyConfigurer.shared.enable(udid: udid, host: "127.0.0.1", port: port)

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = mitmdumpURL
        process.arguments = [
            "-s", addonURL.path,
            "--set", "confdir=~/.mitmproxy",
            "--listen-port", "\(port)",
            "--set", "flow_detail=0"
        ]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutTask = Task.detached(priority: .utility) {
            await Self.pumpJSON(
                from: stdoutPipe.fileHandleForReading,
                deviceID: deviceID,
                onRequest: onRequest
            )
        }
        let stderrTask = Task.detached(priority: .utility) {
            await Self.drain(stderrPipe.fileHandleForReading)
        }

        do {
            try process.run()
        } catch {
            try? await ProxyConfigurer.shared.disable(udid: udid)
            stdoutTask.cancel()
            stderrTask.cancel()
            throw NetworkMonitorError.spawnFailed(error.localizedDescription)
        }

        sessions[deviceID] = Session(
            udid: udid,
            process: process,
            stdoutTask: stdoutTask,
            stderrTask: stderrTask,
            port: port,
            addonURL: addonURL
        )
    }

    func stop(deviceID: String) async {
        guard let session = sessions.removeValue(forKey: deviceID) else { return }
        session.stdoutTask.cancel()
        session.stderrTask.cancel()
        if session.process.isRunning {
            session.process.terminate()
        }
        try? await ProxyConfigurer.shared.disable(udid: session.udid)
    }

    func stopAll() async {
        let deviceIDs = Array(sessions.keys)
        for deviceID in deviceIDs {
            await stop(deviceID: deviceID)
        }
    }

    // MARK: - Port / addon staging

    private static func pickPort(for udid: String) -> Int {
        let base = 18_080
        let offset = abs(udid.hashValue) % 800
        return base + offset
    }

    private static func stagedAddonURL() throws -> URL {
        guard let bundled = Bundle.main.url(forResource: "mitmproxy_addon", withExtension: "py") else {
            throw NetworkMonitorError.addonMissing
        }
        let destDir = FileManager.default.temporaryDirectory
            .appending(path: "KittyFarm-mitmproxy")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appending(path: "mitmproxy_addon.py")
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: bundled, to: dest)
        return dest
    }

    // MARK: - Output pumps

    private static func pumpJSON(
        from handle: FileHandle,
        deviceID: String,
        onRequest: @escaping RequestHandler
    ) async {
        var buffer = Data()
        while !Task.isCancelled {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 4096) ?? Data()
            } catch {
                break
            }
            if chunk.isEmpty { break }
            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.prefix(upTo: newlineIndex)
                buffer.removeSubrange(...newlineIndex)
                emitLine(Data(lineData), onRequest: onRequest)
            }
        }
    }

    private static func emitLine(_ lineData: Data, onRequest: RequestHandler) {
        guard let line = String(data: lineData, encoding: .utf8) else { return }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let magic = "KITTYFARM_FLOW "
        guard trimmed.hasPrefix(magic) else { return }
        let jsonText = String(trimmed.dropFirst(magic.count))
        guard let jsonData = jsonText.data(using: .utf8),
              let request = decodeRequest(from: jsonData) else {
            return
        }
        onRequest(request)
    }

    private static func drain(_ handle: FileHandle) async {
        while !Task.isCancelled {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 4096) ?? Data()
            } catch {
                break
            }
            if chunk.isEmpty { break }
        }
    }

    // MARK: - JSON decoding

    private static func decodeRequest(from data: Data) -> NetworkRequest? {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            return nil
        }
        guard let id = dict["id"] as? String,
              let method = dict["method"] as? String,
              let url = dict["url"] as? String else {
            return nil
        }

        let started = (dict["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        let status = dict["status"] as? Int
        let error = dict["error"] as? String
        let scheme = dict["scheme"] as? String ?? ""
        let host = dict["host"] as? String ?? ""
        let path = dict["path"] as? String ?? ""
        let requestHeaders = decodeHeaders(dict["requestHeaders"])
        let responseHeaders = decodeHeaders(dict["responseHeaders"])
        let requestBody = decodeBody(dict["requestBody"])
        let requestBodyTruncated = dict["requestBodyTruncated"] as? Bool ?? false
        let responseBody = decodeBody(dict["responseBody"])
        let responseBodyTruncated = dict["responseBodyTruncated"] as? Bool ?? false
        let durationMs = dict["durationMs"] as? Double
        let bytesSent = dict["bytesSent"] as? Int ?? 0
        let bytesReceived = dict["bytesReceived"] as? Int ?? 0
        let clientPort = dict["clientPort"] as? Int

        return NetworkRequest(
            id: id,
            startedAt: started,
            method: method,
            url: url,
            scheme: scheme,
            host: host,
            path: path,
            status: status,
            error: error,
            requestHeaders: requestHeaders,
            requestBody: requestBody,
            requestBodyTruncated: requestBodyTruncated,
            responseHeaders: responseHeaders,
            responseBody: responseBody,
            responseBodyTruncated: responseBodyTruncated,
            durationMs: durationMs,
            bytesSent: bytesSent,
            bytesReceived: bytesReceived,
            sourcePID: nil,
            clientPort: clientPort
        )
    }

    private static func decodeHeaders(_ value: Any?) -> [(String, String)] {
        guard let array = value as? [[Any]] else { return [] }
        var pairs: [(String, String)] = []
        pairs.reserveCapacity(array.count)
        for item in array {
            guard item.count >= 2,
                  let key = item[0] as? String,
                  let val = item[1] as? String else { continue }
            pairs.append((key, val))
        }
        return pairs
    }

    private static func decodeBody(_ value: Any?) -> Data? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return Data(base64Encoded: string)
    }
}

enum NetworkStatus: Sendable, Equatable {
    case enabled
    case mitmproxyMissing
    case failed(String)
}

enum NetworkMonitorError: LocalizedError, Sendable {
    case mitmproxyMissing
    case caGenerationFailed
    case caInstallFailed(String)
    case addonMissing
    case spawnFailed(String)

    var errorDescription: String? {
        switch self {
        case .mitmproxyMissing:
            return "mitmproxy is not installed. Run `brew install mitmproxy`, then reconnect the device."
        case .caGenerationFailed:
            return "mitmproxy root certificate was not generated. Run `mitmdump` once manually to initialize."
        case let .caInstallFailed(detail):
            return "Failed to install mitmproxy root certificate into the simulator: \(detail)"
        case .addonMissing:
            return "mitmproxy_addon.py is missing from the KittyFarm bundle."
        case let .spawnFailed(detail):
            return "Failed to spawn mitmdump: \(detail)"
        }
    }
}

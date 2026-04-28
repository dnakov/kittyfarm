import Foundation
import Network

enum LocalControlServerError: LocalizedError {
    case missingRequest
    case malformedRequest
    case unauthorized
    case routeNotFound(String, String)
    case portAllocationFailed

    var errorDescription: String? {
        switch self {
        case .missingRequest:
            return "Missing HTTP request."
        case .malformedRequest:
            return "Malformed HTTP request."
        case .unauthorized:
            return "Missing or invalid local control token."
        case .routeNotFound(let method, let path):
            return "No local control route for \(method) \(path)."
        case .portAllocationFailed:
            return "Could not allocate a localhost port for the local control server."
        }
    }
}

@MainActor
final class LocalControlServer {
    static let defaultPort: UInt16 = 47892

    private let store: KittyFarmStore
    private let token: String
    private let configURL: URL
    private var listener: NWListener?

    private(set) var port: UInt16 = 0

    init(store: KittyFarmStore) throws {
        self.store = store
        let directory = try Self.configDirectory()
        configURL = directory.appending(path: "control-api.json")

        if let configData = try? Data(contentsOf: configURL),
           let config = try? JSONDecoder().decode(LocalControlConfig.self, from: configData),
           !config.token.isEmpty {
            token = config.token
        } else {
            token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
    }

    func start() async throws {
        guard listener == nil else { return }

        guard let nwPort = NWEndpoint.Port(rawValue: Self.defaultPort) else {
            throw LocalControlServerError.portAllocationFailed
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        let listener = try NWListener(using: parameters)
        listener.service = nil
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.handle(connection)
            }
        }
        listener.start(queue: DispatchQueue(label: "KittyFarm.LocalControlServer"))

        port = Self.defaultPort
        self.listener = listener
        try writeConfig()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "KittyFarm.LocalControlConnection"))
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if error != nil {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if let request = HTTPRequest(data: nextBuffer) {
                Task { @MainActor in
                    await self.respond(to: request, on: connection)
                }
                return
            }

            if isComplete {
                Task { @MainActor in
                    await self.sendError(LocalControlServerError.malformedRequest, status: 400, on: connection)
                }
                return
            }

            Task { @MainActor in
                self.receive(on: connection, buffer: nextBuffer)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) async {
        if request.path == "/mcp" {
            let response = await LocalControlMCPHandler.respond(to: request.body, store: store)
            send(
                body: response.body,
                status: response.status,
                contentType: response.contentType,
                headers: response.headers,
                on: connection
            )
            return
        }

        do {
            guard request.bearerToken == token else {
                throw LocalControlServerError.unauthorized
            }

            let response = try await route(request)
            sendJSON(response, status: 200, on: connection)
        } catch LocalControlServerError.unauthorized {
            await sendError(LocalControlServerError.unauthorized, status: 401, on: connection)
        } catch let error as LocalControlServerError {
            await sendError(error, status: 404, on: connection)
        } catch {
            await sendError(error, status: 400, on: connection)
        }
    }

    private func route(_ request: HTTPRequest) async throws -> any Encodable {
        switch (request.method, request.path) {
        case ("GET", "/status"):
            return store.localControlStatusResponse()
        case ("GET", "/devices"):
            return store.localControlDevicesResponse()
        case ("GET", "/logs"):
            return store.localControlLogs(limit: Int(request.query["limit"] ?? "") ?? 200)
        case ("GET", "/screenshot"):
            let deviceId = try request.requiredQuery("deviceId")
            return try store.localControlScreenshot(deviceId: deviceId)
        case ("GET", "/accessibility"):
            let deviceId = try request.requiredQuery("deviceId")
            return try await store.localControlAccessibilityTree(deviceId: deviceId, bundleId: request.query["bundleId"])
        case ("POST", "/devices/connect"):
            let body: LocalControlConnectRequest = try request.decodeBody()
            return try await store.localControlConnect(deviceId: body.deviceId)
        case ("POST", "/devices/disconnect"):
            let body: LocalControlConnectRequest = try request.decodeBody()
            return try await store.localControlDisconnect(deviceId: body.deviceId)
        case ("POST", "/input/tap"):
            return try await store.localControlTap(request.decodeBody())
        case ("POST", "/input/swipe"):
            return try await store.localControlSwipe(request.decodeBody())
        case ("POST", "/input/type"):
            return try await store.localControlType(request.decodeBody())
        case ("POST", "/input/home"):
            let body: LocalControlDeviceRequest = try request.decodeBody()
            return try await store.localControlPressHome(deviceId: body.deviceId)
        case ("POST", "/input/rotate"):
            let body: LocalControlDeviceRequest = try request.decodeBody()
            return try await store.localControlRotate(deviceId: body.deviceId)
        case ("POST", "/input/open-app"):
            return try await store.localControlOpenApp(request.decodeBody())
        case ("POST", "/element/find"):
            return try await store.localControlFindElement(request.decodeBody())
        case ("POST", "/assert/visible"):
            return try await store.localControlAssertVisible(request.decodeBody())
        case ("POST", "/assert/not-visible"):
            return try await store.localControlAssertNotVisible(request.decodeBody())
        case ("POST", "/wait-for"):
            return try await store.localControlWaitFor(request.decodeBody())
        case ("POST", "/project/discover"):
            return try await store.localControlDiscoverProject(request.decodeBody())
        case ("POST", "/build/run"):
            return try await store.localControlBuildAndRun(request.decodeBody())
        default:
            throw LocalControlServerError.routeNotFound(request.method, request.path)
        }
    }

    private func sendJSON(_ value: any Encodable, status: Int, on connection: NWConnection) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let body = try encoder.encode(AnyEncodable(value))
            send(body: body, status: status, contentType: "application/json", on: connection)
        } catch {
            Task { @MainActor in
                await self.sendError(error, status: 500, on: connection)
            }
        }
    }

    private func sendError(_ error: Error, status: Int, on connection: NWConnection) async {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let body = (try? JSONEncoder().encode(LocalControlErrorResponse(error: message))) ?? Data()
        send(body: body, status: status, contentType: "application/json", on: connection)
    }

    private func send(
        body: Data,
        status: Int,
        contentType: String,
        headers: [String: String] = [:],
        on connection: NWConnection
    ) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 500: reason = "Internal Server Error"
        default: reason = "Response"
        }
        var response = Data("HTTP/1.1 \(status) \(reason)\r\n".utf8)
        response.append(Data("Content-Type: \(contentType)\r\n".utf8))
        response.append(Data("Content-Length: \(body.count)\r\n".utf8))
        for (name, value) in headers {
            response.append(Data("\(name): \(value)\r\n".utf8))
        }
        response.append(Data("Connection: close\r\n\r\n".utf8))
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func writeConfig() throws {
        let baseURL = "http://127.0.0.1:\(port)"
        let config = LocalControlConfig(baseURL: baseURL, mcpURL: "\(baseURL)/mcp", token: token)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: configURL, options: .atomic)
    }

    private static func configDirectory() throws -> URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "KittyFarm")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    init?(data: Data) {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<separator.lowerBound]
        let bodyStart = separator.upperBound
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        method = String(parts[0]).uppercased()
        let rawPath = String(parts[1])
        let components = URLComponents(string: rawPath)
        path = components?.path ?? rawPath
        query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })

        var parsedHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let range = line.range(of: ":") else { continue }
            let key = line[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            parsedHeaders[key] = value
        }
        headers = parsedHeaders

        let length = Int(parsedHeaders["content-length"] ?? "0") ?? 0
        guard data.count >= bodyStart + length else { return nil }
        body = Data(data[bodyStart..<(bodyStart + length)])
    }

    var bearerToken: String? {
        guard let authorization = headers["authorization"] else { return nil }
        let prefix = "Bearer "
        guard authorization.hasPrefix(prefix) else { return nil }
        return String(authorization.dropFirst(prefix.count))
    }

    func requiredQuery(_ name: String) throws -> String {
        guard let value = query[name], !value.isEmpty else {
            throw LocalControlStoreError.invalidRequest("Missing query parameter: \(name)")
        }
        return value
    }

    func decodeBody<T: Decodable>() throws -> T {
        try JSONDecoder().decode(T.self, from: body)
    }
}

private struct AnyEncodable: Encodable {
    let value: any Encodable

    init(_ value: any Encodable) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

import Foundation
import Network

private final class ListenResult: @unchecked Sendable {
    var port: UInt16?
    var error: Error?
}

final class ProbeHTTPServer: @unchecked Sendable {
    typealias Handler = (String, String) -> (statusCode: Int, body: Data, contentType: String)

    private let port: UInt16
    private var listener: NWListener?
    private let handler: Handler

    init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    func start() throws -> UInt16 {
        let parameters = NWParameters.tcp
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        let ready = DispatchSemaphore(value: 0)
        let result = ListenResult()

        listener.stateUpdateHandler = { [result] state in
            switch state {
            case .ready:
                if let actualPort = listener.port?.rawValue {
                    result.port = actualPort
                }
                ready.signal()
            case .failed(let error):
                result.error = error
                ready.signal()
            default:
                break
            }
        }

        listener.start(queue: DispatchQueue(label: "KittyProbe.HTTP"))
        ready.wait()

        if let error = result.error {
            throw error
        }

        return result.port ?? port
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "KittyProbe.HTTP.conn"))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }

            let request = String(decoding: data, as: UTF8.self)
            let (method, path) = Self.parseRequestLine(request)
            let (statusCode, body, contentType) = self.handler(method, path)
            let response = Self.buildHTTPResponse(statusCode: statusCode, contentType: contentType, body: body)

            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private static func parseRequestLine(_ request: String) -> (method: String, path: String) {
        let firstLine = request.prefix(while: { $0 != "\r" && $0 != "\n" })
        let parts = firstLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return ("GET", "/") }
        return (String(parts[0]), String(parts[1]))
    }

    private static func buildHTTPResponse(statusCode: Int, contentType: String, body: Data) -> Data {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        var header = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"

        var response = Data(header.utf8)
        response.append(body)
        return response
    }
}

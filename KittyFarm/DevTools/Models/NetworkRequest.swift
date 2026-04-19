import Foundation

struct NetworkRequest: Identifiable, Sendable, Hashable {
    let id: String
    let startedAt: Date
    let method: String
    let url: String
    let scheme: String
    let host: String
    let path: String
    let status: Int?
    let error: String?
    let requestHeaders: [(String, String)]
    let requestBody: Data?
    let requestBodyTruncated: Bool
    let responseHeaders: [(String, String)]
    let responseBody: Data?
    let responseBodyTruncated: Bool
    let durationMs: Double?
    let bytesSent: Int
    let bytesReceived: Int
    let sourcePID: Int32?
    let clientPort: Int?

    static func == (lhs: NetworkRequest, rhs: NetworkRequest) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

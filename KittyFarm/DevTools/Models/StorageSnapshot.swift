import Foundation

struct StorageSnapshot: Sendable {
    let rootPath: String
    let root: StorageNode
    let userDefaults: [String: String]
    let capturedAt: Date
}

struct StorageNode: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modifiedAt: Date?
    let children: [StorageNode]?
}

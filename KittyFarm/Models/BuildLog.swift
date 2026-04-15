import Foundation

enum BuildLogSource: String, Sendable {
    case command
    case stdout
    case stderr
    case system
}

enum BuildLogSeverity: Sendable {
    case info
    case warning
    case error
}

struct BuildLogScope: Hashable, Sendable {
    static let build = BuildLogScope(id: "build", title: "Build")

    let id: String
    let title: String
}

struct BuildLogFilter: Identifiable, Hashable, Sendable {
    static let all = BuildLogFilter(id: "all", title: "All")

    let id: String
    let title: String
}

struct BuildLogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp = Date()
    let source: BuildLogSource
    let severity: BuildLogSeverity
    let scope: BuildLogScope
    let message: String
}

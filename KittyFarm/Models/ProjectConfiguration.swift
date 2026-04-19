import Foundation

struct IOSProjectConfiguration: Codable, Equatable, Sendable {
    var projectPath: String
    var scheme: String
    var bundleIdentifier: String?

    var projectURL: URL {
        URL(fileURLWithPath: projectPath)
    }

    var displayName: String {
        projectURL.deletingPathExtension().lastPathComponent
    }

    var isWorkspace: Bool {
        projectURL.pathExtension == "xcworkspace"
    }
}

struct AndroidProjectConfiguration: Codable, Equatable, Sendable {
    var projectDirectoryPath: String
    var applicationID: String
    var gradleTask: String = "installDebug"

    var projectDirectoryURL: URL {
        URL(fileURLWithPath: projectDirectoryPath)
    }

    var gradlewURL: URL {
        projectDirectoryURL.appending(path: "gradlew")
    }

    var displayName: String {
        projectDirectoryURL.lastPathComponent
    }
}

import Foundation

struct IOSProjectConfiguration: Codable, Equatable, Sendable {
    var projectPath: String
    var scheme: String
    var bundleIdentifier: String?
    var schemes: [String]

    init(
        projectPath: String,
        scheme: String,
        bundleIdentifier: String?,
        schemes: [String] = []
    ) {
        self.projectPath = projectPath
        self.scheme = scheme
        self.bundleIdentifier = bundleIdentifier
        self.schemes = schemes
    }

    private enum CodingKeys: String, CodingKey {
        case projectPath
        case scheme
        case bundleIdentifier
        case schemes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectPath = try container.decode(String.self, forKey: .projectPath)
        scheme = try container.decode(String.self, forKey: .scheme)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        schemes = try container.decodeIfPresent([String].self, forKey: .schemes) ?? []
    }

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

struct AndroidAppTarget: Codable, Equatable, Sendable, Identifiable {
    var moduleName: String
    var applicationID: String
    var gradleTask: String

    var id: String { gradleTask }

    var displayName: String {
        moduleName.isEmpty ? gradleTask : moduleName
    }
}

struct AndroidProjectConfiguration: Codable, Equatable, Sendable {
    var projectDirectoryPath: String
    var applicationID: String
    var gradleTask: String = "installDebug"
    var appTargets: [AndroidAppTarget] = []

    private enum CodingKeys: String, CodingKey {
        case projectDirectoryPath
        case applicationID
        case gradleTask
        case appTargets
    }

    init(
        projectDirectoryPath: String,
        applicationID: String,
        gradleTask: String = "installDebug",
        appTargets: [AndroidAppTarget] = []
    ) {
        self.projectDirectoryPath = projectDirectoryPath
        self.applicationID = applicationID
        self.gradleTask = gradleTask
        self.appTargets = appTargets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectDirectoryPath = try container.decode(String.self, forKey: .projectDirectoryPath)
        applicationID = try container.decode(String.self, forKey: .applicationID)
        gradleTask = try container.decodeIfPresent(String.self, forKey: .gradleTask) ?? "installDebug"
        appTargets = try container.decodeIfPresent([AndroidAppTarget].self, forKey: .appTargets) ?? []
    }

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

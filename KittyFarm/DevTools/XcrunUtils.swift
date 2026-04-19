import Foundation

enum XcrunUtils {
    static var xcrunURL: URL {
        let environment = ProcessInfo.processInfo.environment

        if let developerDir = environment["DEVELOPER_DIR"], !developerDir.isEmpty {
            return URL(fileURLWithPath: developerDir)
                .appending(path: "usr/bin/xcrun")
        }

        return URL(fileURLWithPath: "/usr/bin/xcrun")
    }

    static func simctl(_ args: [String], environment: [String: String]? = nil) -> ProcessRunner.Command {
        .init(
            executableURL: xcrunURL,
            arguments: ["simctl"] + args,
            environment: environment ?? ProcessInfo.processInfo.environment
        )
    }
}

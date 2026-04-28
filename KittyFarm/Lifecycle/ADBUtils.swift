import Foundation

enum ADBUtils {
    private static var defaultSDKRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library")
            .appending(path: "Android")
            .appending(path: "sdk")
    }

    static var binaryURL: URL {
        let environment = ProcessInfo.processInfo.environment

        if let sdkRoot = environment["ANDROID_SDK_ROOT"], !sdkRoot.isEmpty {
            return URL(fileURLWithPath: sdkRoot).appending(path: "platform-tools/adb")
        }

        if let androidHome = environment["ANDROID_HOME"], !androidHome.isEmpty {
            return URL(fileURLWithPath: androidHome).appending(path: "platform-tools/adb")
        }

        return defaultSDKRootURL.appending(path: "platform-tools/adb")
    }

    static var emulatorBinaryURL: URL {
        if let androidHome = ProcessInfo.processInfo.environment["ANDROID_HOME"] {
            return URL(fileURLWithPath: androidHome)
                .appending(path: "emulator")
                .appending(path: "emulator")
        }

        if let androidSDKRoot = ProcessInfo.processInfo.environment["ANDROID_SDK_ROOT"] {
            return URL(fileURLWithPath: androidSDKRoot)
                .appending(path: "emulator")
                .appending(path: "emulator")
        }

        return defaultSDKRootURL
            .appending(path: "emulator")
            .appending(path: "emulator")
    }

    static func resolveSerial(avdName: String) async throws -> String {
        let devicesResult = try await ProcessRunner.run(.init(
            executableURL: binaryURL,
            arguments: ["devices"]
        ))
        try devicesResult.requireSuccess("adb devices")

        let lines = devicesResult.stdout
            .split(separator: "\n")
            .dropFirst()
            .map(String.init)

        for line in lines {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, parts[1] == "device" else { continue }
            let serial = String(parts[0])
            guard serial.hasPrefix("emulator-") else { continue }

            let avdResult = try await ProcessRunner.run(.init(
                executableURL: binaryURL,
                arguments: ["-s", serial, "emu", "avd", "name"]
            ))
            guard avdResult.terminationStatus == 0 else { continue }

            let resolvedName = avdResult.stdout
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty && $0 != "OK" }) ?? ""

            if resolvedName == avdName {
                return serial
            }
        }

        throw ADBError.serialNotFound(avdName)
    }
}

enum ADBError: LocalizedError {
    case serialNotFound(String)

    var errorDescription: String? {
        switch self {
        case .serialNotFound(let avdName):
            return "Could not find ADB serial for emulator \"\(avdName)\". Is it running?"
        }
    }
}

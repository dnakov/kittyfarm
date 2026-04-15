import Foundation

enum RuntimeLogTarget: Hashable, Sendable {
    case iOSSimulator(udid: String, processName: String, deviceLabel: String)
    case androidEmulator(serial: String, applicationID: String, deviceLabel: String)

    var id: String {
        switch self {
        case let .iOSSimulator(udid, processName, _):
            return "ios-\(udid)-\(processName)"
        case let .androidEmulator(serial, applicationID, _):
            return "android-\(serial)-\(applicationID)"
        }
    }

    var displayName: String {
        switch self {
        case let .iOSSimulator(udid, _, deviceLabel):
            return "\(deviceLabel) (\(String(udid.prefix(8))))"
        case let .androidEmulator(serial, _, deviceLabel):
            return "\(deviceLabel) (\(serial))"
        }
    }
}

actor RuntimeLogStreamManager {
    typealias Logger = BuildPlayRunner.Logger

    private struct Session {
        let process: Process
        let stdoutTask: Task<Void, Never>
        let stderrTask: Task<Void, Never>
    }

    private var sessions: [String: Session] = [:]

    func replaceStreams(for targets: [RuntimeLogTarget], logger: @escaping Logger) async {
        await stopAll()

        for target in targets {
            do {
                try await startStream(for: target, logger: logger)
            } catch {
                await logger(.system, "Failed to start runtime log stream for \(target.displayName): \(error.localizedDescription)")
            }
        }
    }

    func stopAll() async {
        for session in sessions.values {
            session.stdoutTask.cancel()
            session.stderrTask.cancel()
            if session.process.isRunning {
                session.process.terminate()
            }
        }

        sessions.removeAll()
    }

    private func startStream(for target: RuntimeLogTarget, logger: @escaping Logger) async throws {
        let command = try await makeCommand(for: target)
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.environment = command.environment
        process.currentDirectoryURL = command.currentDirectoryURL
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let devicePrefix = "[device \(target.displayName)]"

        let stdoutTask = Task.detached(priority: .utility) {
            await pumpLogStream(
                from: stdoutPipe.fileHandleForReading,
                prefix: devicePrefix,
                source: .stdout,
                logger: logger
            )
        }

        let stderrTask = Task.detached(priority: .utility) {
            await pumpLogStream(
                from: stderrPipe.fileHandleForReading,
                prefix: devicePrefix,
                source: .stderr,
                logger: logger
            )
        }

        try process.run()
        await logger(.command, "\(devicePrefix) $ \(shellDescription(for: command))")
        await logger(.system, "\(devicePrefix) Streaming runtime logs")

        process.terminationHandler = { process in
            Task {
                await logger(.system, "\(devicePrefix) Runtime log stream ended with exit code \(process.terminationStatus)")
            }
        }

        sessions[target.id] = Session(process: process, stdoutTask: stdoutTask, stderrTask: stderrTask)
    }

    private func makeCommand(for target: RuntimeLogTarget) async throws -> ProcessRunner.Command {
        switch target {
        case let .iOSSimulator(udid, processName, _):
            return .init(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: [
                    "simctl", "spawn", udid,
                    "log", "stream",
                    "--style", "compact",
                    "--level", "debug",
                    "--process", processName
                ]
            )

        case let .androidEmulator(serial, applicationID, _):
            let adbURL = adbBinaryURL()
            let pidResult = try await ProcessRunner.run(.init(
                executableURL: adbURL,
                arguments: ["-s", serial, "shell", "pidof", "-s", applicationID]
            ))
            try pidResult.requireSuccess("adb pidof \(applicationID)")

            let pid = pidResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pid.isEmpty else {
                throw RuntimeLogStreamError.missingAndroidPID(applicationID, serial)
            }

            return .init(
                executableURL: adbURL,
                arguments: ["-s", serial, "logcat", "--format", "brief", "--pid", pid]
            )
        }
    }

    private func adbBinaryURL() -> URL {
        let environment = ProcessInfo.processInfo.environment

        if let sdkRoot = environment["ANDROID_SDK_ROOT"], !sdkRoot.isEmpty {
            return URL(fileURLWithPath: sdkRoot).appending(path: "platform-tools/adb")
        }

        if let androidHome = environment["ANDROID_HOME"], !androidHome.isEmpty {
            return URL(fileURLWithPath: androidHome).appending(path: "platform-tools/adb")
        }

        return URL(fileURLWithPath: "/Users/sigkitten/Library/Android/sdk/platform-tools/adb")
    }

    private func shellDescription(for command: ProcessRunner.Command) -> String {
        ([command.executableURL.path] + command.arguments)
            .map(shellEscape)
            .joined(separator: " ")
    }

    private func shellEscape(_ argument: String) -> String {
        guard argument.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || argument.contains("'") else {
            return argument
        }
        return "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private func pumpLogStream(
    from handle: FileHandle,
    prefix: String,
    source: BuildLogSource,
    logger: @escaping BuildPlayRunner.Logger
) async {
    do {
        var buffer = Data()

        while !Task.isCancelled {
            let chunk = try handle.read(upToCount: 4096) ?? Data()
            guard !chunk.isEmpty else { break }

            buffer.append(chunk)
            await emitAvailableRuntimeLogLines(from: &buffer, prefix: prefix, source: source, logger: logger)
        }

        await emitRemainingRuntimeLogLine(from: &buffer, prefix: prefix, source: source, logger: logger)
    } catch {
        await logger(.system, "\(prefix) stream error: \(error.localizedDescription)")
    }
}

private func emitAvailableRuntimeLogLines(
    from buffer: inout Data,
    prefix: String,
    source: BuildLogSource,
    logger: @escaping BuildPlayRunner.Logger
) async {
    while let newlineIndex = buffer.firstIndex(of: 0x0A) {
        let lineData = buffer.prefix(upTo: newlineIndex)
        buffer.removeSubrange(...newlineIndex)
        await emitRuntimeLogLine(Data(lineData), prefix: prefix, source: source, logger: logger)
    }
}

private func emitRemainingRuntimeLogLine(
    from buffer: inout Data,
    prefix: String,
    source: BuildLogSource,
    logger: @escaping BuildPlayRunner.Logger
) async {
    guard !buffer.isEmpty else { return }
    let trailingData = buffer
    buffer.removeAll(keepingCapacity: true)
    await emitRuntimeLogLine(trailingData, prefix: prefix, source: source, logger: logger)
}

private func emitRuntimeLogLine(
    _ lineData: Data,
    prefix: String,
    source: BuildLogSource,
    logger: @escaping BuildPlayRunner.Logger
) async {
    let line = String(decoding: lineData, as: UTF8.self)
        .trimmingCharacters(in: .newlines)
    guard !line.isEmpty else { return }
    await logger(source, "\(prefix) \(line)")
}

enum RuntimeLogStreamError: LocalizedError {
    case missingAndroidPID(String, String)

    var errorDescription: String? {
        switch self {
        case let .missingAndroidPID(applicationID, serial):
            return "Couldn't find a running pid for \(applicationID) on \(serial)."
        }
    }
}

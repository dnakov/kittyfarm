import Foundation

struct ProcessRunner {
    struct Command: Sendable {
        var executableURL: URL
        var arguments: [String] = []
        var environment: [String: String] = ProcessInfo.processInfo.environment
        var currentDirectoryURL: URL?
        var stdinData: Data?
    }

    struct OutputEvent: Sendable {
        enum Stream: Sendable {
            case stdout
            case stderr
        }

        let stream: Stream
        let text: String
    }

    struct Result: Sendable {
        let stdoutData: Data
        let stderrData: Data
        let terminationStatus: Int32

        var stdout: String {
            String(decoding: stdoutData, as: UTF8.self)
        }

        var stderr: String {
            String(decoding: stderrData, as: UTF8.self)
        }

        func requireSuccess(_ context: String) throws {
            guard terminationStatus == 0 else {
                throw ProcessRunnerError.failed(context: context, stdout: stdout, stderr: stderr, code: terminationStatus)
            }
        }
    }

    static func run(
        _ command: Command,
        onOutput: (@Sendable (OutputEvent) async -> Void)? = nil
    ) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdinPipe = command.stdinData == nil ? nil : Pipe()

            process.executableURL = command.executableURL
            process.arguments = command.arguments
            process.environment = command.environment
            process.currentDirectoryURL = command.currentDirectoryURL
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = stdinPipe

            let stdoutTask = Task {
                try await collectOutput(
                    from: stdoutPipe.fileHandleForReading,
                    stream: .stdout,
                    onOutput: onOutput
                )
            }

            let stderrTask = Task {
                try await collectOutput(
                    from: stderrPipe.fileHandleForReading,
                    stream: .stderr,
                    onOutput: onOutput
                )
            }

            try process.run()

            if let stdinPipe, let stdinData = command.stdinData {
                try stdinPipe.fileHandleForWriting.write(contentsOf: stdinData)
                try stdinPipe.fileHandleForWriting.close()
            }

            let terminationStatus = try await waitForProcess(process)

            let stdoutData = try await stdoutTask.value
            let stderrData = try await stderrTask.value

            return Result(
                stdoutData: stdoutData,
                stderrData: stderrData,
                terminationStatus: terminationStatus
            )
        }.value
    }

    private static func collectOutput(
        from handle: FileHandle,
        stream: OutputEvent.Stream,
        onOutput: (@Sendable (OutputEvent) async -> Void)?
    ) async throws -> Data {
        var collected = Data()
        var pendingLineBuffer = Data()

        while !Task.isCancelled {
            let chunk = try handle.read(upToCount: 4096) ?? Data()
            guard !chunk.isEmpty else { break }

            collected.append(chunk)
            pendingLineBuffer.append(chunk)
            try await emitAvailableLines(from: &pendingLineBuffer, stream: stream, onOutput: onOutput)
        }

        try await emitRemainingLine(from: &pendingLineBuffer, stream: stream, onOutput: onOutput)
        return collected
    }

    private static func emitAvailableLines(
        from buffer: inout Data,
        stream: OutputEvent.Stream,
        onOutput: (@Sendable (OutputEvent) async -> Void)?
    ) async throws {
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: newlineIndex)
            buffer.removeSubrange(...newlineIndex)
            try await emitLine(Data(lineData), stream: stream, onOutput: onOutput)
        }
    }

    private static func emitRemainingLine(
        from buffer: inout Data,
        stream: OutputEvent.Stream,
        onOutput: (@Sendable (OutputEvent) async -> Void)?
    ) async throws {
        guard !buffer.isEmpty else { return }
        let trailingData = buffer
        buffer.removeAll(keepingCapacity: true)
        try await emitLine(trailingData, stream: stream, onOutput: onOutput)
    }

    private static func emitLine(
        _ lineData: Data,
        stream: OutputEvent.Stream,
        onOutput: (@Sendable (OutputEvent) async -> Void)?
    ) async throws {
        let line = String(decoding: lineData, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        guard !line.isEmpty else { return }
        await onOutput?(OutputEvent(stream: stream, text: line))
    }

    private static func waitForProcess(_ process: Process) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finishedProcess in
                continuation.resume(returning: finishedProcess.terminationStatus)
            }
        }
    }
}

enum ProcessRunnerError: LocalizedError {
    case failed(context: String, stdout: String, stderr: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case let .failed(context, stdout, stderr, code):
            let details = [stderr.trimmingCharacters(in: .whitespacesAndNewlines), stdout.trimmingCharacters(in: .whitespacesAndNewlines)]
                .first { !$0.isEmpty } ?? "No command output."
            return "\(context) failed with exit code \(code): \(details)"
        }
    }
}

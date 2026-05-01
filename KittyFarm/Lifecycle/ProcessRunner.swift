import Foundation

private final class ProcessRunnerProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var terminationRequested = false

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = terminationRequested
        lock.unlock()

        if shouldTerminate, process.isRunning {
            process.terminate()
        }
    }

    var isTerminationRequested: Bool {
        lock.lock()
        let value = terminationRequested
        lock.unlock()
        return value
    }

    func terminate() {
        lock.lock()
        terminationRequested = true
        let process = self.process
        lock.unlock()

        if process?.isRunning == true {
            process?.terminate()
        }
    }
}

private final class ProcessRunnerRegistry: @unchecked Sendable {
    static let shared = ProcessRunnerRegistry()

    private let lock = NSLock()
    private var processes: [Int32: Process] = [:]

    func insert(_ process: Process) {
        lock.lock()
        processes[process.processIdentifier] = process
        lock.unlock()
    }

    func remove(_ process: Process) {
        lock.lock()
        processes.removeValue(forKey: process.processIdentifier)
        lock.unlock()
    }

    func terminateAll() {
        lock.lock()
        let runningProcesses = Array(processes.values)
        lock.unlock()

        for process in runningProcesses where process.isRunning {
            process.terminate()
        }
    }
}

private final class ProcessRunnerWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32, Never>?

    init(_ continuation: CheckedContinuation<Int32, Never>) {
        self.continuation = continuation
    }

    func resume(_ status: Int32) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: status)
    }
}

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
        let processBox = ProcessRunnerProcessBox()

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                let stdinPipe = command.stdinData == nil ? nil : Pipe()
                processBox.set(process)

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
                ProcessRunnerRegistry.shared.insert(process)
                defer {
                    ProcessRunnerRegistry.shared.remove(process)
                }

                if processBox.isTerminationRequested, process.isRunning {
                    process.terminate()
                }

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
        } onCancel: {
            processBox.terminate()
        }
    }

    static func terminateAllRunning() {
        ProcessRunnerRegistry.shared.terminateAll()
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
        if !process.isRunning {
            return process.terminationStatus
        }

        return await withCheckedContinuation { continuation in
            let waiter = ProcessRunnerWaiter(continuation)
            process.terminationHandler = { finishedProcess in
                waiter.resume(finishedProcess.terminationStatus)
            }

            if !process.isRunning {
                process.terminationHandler = nil
                waiter.resume(process.terminationStatus)
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

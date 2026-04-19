import Foundation

actor CPUMonitor {
    private struct Session {
        let task: Task<Void, Never>
    }

    private var sessions: [String: Session] = [:]

    func start(
        deviceID: String,
        pid: pid_t,
        onSample: @escaping @Sendable (CPUSample) -> Void
    ) async {
        sessions[deviceID]?.task.cancel()

        let task = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if let sample = await Self.pollOnce(pid: pid) {
                    onSample(sample)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        sessions[deviceID] = Session(task: task)
    }

    func stop(deviceID: String) async {
        sessions[deviceID]?.task.cancel()
        sessions.removeValue(forKey: deviceID)
    }

    func stopAll() async {
        for session in sessions.values {
            session.task.cancel()
        }
        sessions.removeAll()
    }

    func captureDeepSample(pid: pid_t, durationSec: Int) async throws -> String {
        let timeoutSec = UInt64(max(durationSec + 10, 20))

        let command = ProcessRunner.Command(
            executableURL: URL(fileURLWithPath: "/usr/bin/sample"),
            arguments: [String(pid), String(durationSec), "-mayDie"]
        )

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let result = try await ProcessRunner.run(command)
                return result.stdout
            }

            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSec * 1_000_000_000)
                throw CPUMonitorError.sampleTimeout(pid: pid)
            }

            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    // MARK: - Open-ended record/stop

    /// Long-running `sample` invocation that flushes its full report when
    /// stopped via SIGINT. Use for "Record / Stop" UX where the user controls
    /// when sampling ends.
    final class DeepSampleRecording: @unchecked Sendable {
        let pid: pid_t
        let startedAt: Date
        let outputURL: URL
        fileprivate let process: Process

        init(pid: pid_t, process: Process, outputURL: URL) {
            self.pid = pid
            self.startedAt = Date()
            self.process = process
            self.outputURL = outputURL
        }
    }

    private var recordings: [pid_t: DeepSampleRecording] = [:]

    /// Start `sample` against `pid` writing to a temp file. Returns a
    /// recording handle to pass to `stopDeepSampleRecording`. Uses
    /// `-file <path>` so we read the report from disk after the child flushes
    /// it (on SIGINT or natural completion) — no pipe streaming needed.
    /// `maxDurationSec` is a runaway guard if the user forgets to stop.
    func startDeepSampleRecording(pid: pid_t, maxDurationSec: Int = 600) throws -> DeepSampleRecording {
        if let existing = recordings[pid], existing.process.isRunning {
            return existing
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kittyfarm-sample-\(pid)-\(UUID().uuidString.prefix(8)).txt")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [
            String(pid), String(maxDurationSec),
            "-mayDie",
            "-file", outputURL.path
        ]
        process.standardOutput = Pipe()       // discard stdout (just status echo)
        process.standardError = Pipe()

        try process.run()

        let recording = DeepSampleRecording(pid: pid, process: process, outputURL: outputURL)
        recordings[pid] = recording
        return recording
    }

    /// SIGINT the running `sample` so it flushes its report, wait for it to
    /// exit, then read the report file. Safe to call if the process has
    /// already completed (e.g. ran past the runaway-guard duration).
    func stopDeepSampleRecording(_ recording: DeepSampleRecording) async throws -> String {
        if recording.process.isRunning {
            kill(recording.process.processIdentifier, SIGINT)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // If already exited, resume directly. Otherwise install a handler.
            if !recording.process.isRunning {
                continuation.resume()
                return
            }
            recording.process.terminationHandler = { _ in continuation.resume() }
            // Re-check now that we've installed the handler (avoids a race where
            // the process exited between the isRunning check and handler install).
            if !recording.process.isRunning {
                recording.process.terminationHandler = nil
                continuation.resume()
            }
        }

        recordings.removeValue(forKey: recording.pid)

        let text = (try? String(contentsOf: recording.outputURL, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: recording.outputURL)
        return text
    }

    func cancelDeepSampleRecording(_ recording: DeepSampleRecording) {
        if recording.process.isRunning {
            recording.process.terminate()
        }
        recordings.removeValue(forKey: recording.pid)
        try? FileManager.default.removeItem(at: recording.outputURL)
    }

    private static func pollOnce(pid: pid_t) async -> CPUSample? {
        async let cpu = fetchCPU(pid: pid)
        async let threads = fetchThreadCount(pid: pid)
        guard let cpu = await cpu else { return nil }
        return CPUSample(timestamp: Date(), cpuPercent: cpu, threadCount: await threads)
    }

    private static func fetchCPU(pid: pid_t) async -> Double? {
        let command = ProcessRunner.Command(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-p", String(pid), "-o", "%cpu="]
        )
        guard let result = try? await ProcessRunner.run(command),
              result.terminationStatus == 0
        else { return nil }
        return Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// macOS `ps` doesn't expose a thread-count column (`nlwp`/`thcount` are Linux-isms).
    /// Count threads via `ps -M` which lists one row per Mach thread; subtract the header.
    private static func fetchThreadCount(pid: pid_t) async -> Int? {
        let command = ProcessRunner.Command(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-M", "-p", String(pid)]
        )
        guard let result = try? await ProcessRunner.run(command),
              result.terminationStatus == 0
        else { return nil }
        let lines = result.stdout.split(whereSeparator: \.isNewline).count
        return lines > 1 ? lines - 1 : nil
    }
}

enum CPUMonitorError: LocalizedError {
    case sampleTimeout(pid: pid_t)

    var errorDescription: String? {
        switch self {
        case let .sampleTimeout(pid):
            return "sample(\(pid)) timed out."
        }
    }
}

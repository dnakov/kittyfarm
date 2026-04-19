import Foundation

enum XctraceRecorderError: LocalizedError {
    case xctraceNotFound
    case recordingFailed(stderr: String)
    case exportFailed(stderr: String)
    case missingTraceBundle(URL, detail: String)

    var errorDescription: String? {
        switch self {
        case .xctraceNotFound:
            return "Could not locate `xctrace` (xcrun xctrace)."
        case .recordingFailed(let stderr):
            return "xctrace record failed: \(stderr.prefix(500))"
        case .exportFailed(let stderr):
            return "xctrace export failed: \(stderr.prefix(500))"
        case let .missingTraceBundle(_, detail):
            return "xctrace did not produce a trace bundle. \(detail)"
        }
    }
}

/// Wraps `xctrace record --template "Time Profiler"` for record/stop UX. The
/// process flushes a usable trace bundle on SIGINT, verified empirically.
actor XctraceRecorder {
    final class Session: @unchecked Sendable {
        let pid: pid_t
        let startedAt: Date
        let traceURL: URL
        fileprivate let process: Process
        fileprivate let stderrPipe: Pipe
        fileprivate let stdoutPipe: Pipe

        init(pid: pid_t, process: Process, traceURL: URL, stderrPipe: Pipe, stdoutPipe: Pipe) {
            self.pid = pid
            self.startedAt = Date()
            self.process = process
            self.stderrPipe = stderrPipe
            self.stdoutPipe = stdoutPipe
            self.traceURL = traceURL
        }
    }

    private var sessions: [pid_t: Session] = [:]

    /// Start a recording attached to `pid`. The trace bundle is written to a
    /// fresh temp directory; `maxDurationSec` is a runaway guard. Waits up to
    /// `attachTimeoutSec` for xctrace to confirm it attached (by either creating
    /// the bundle or exiting with an error) — that way Stop never gets called
    /// against a dead recorder, and attach errors surface immediately.
    ///
    /// `simulatorUDID` is required for iOS simulator processes. Without
    /// `--device <udid>`, xctrace's host-PID lookup can't see processes hosted
    /// inside a CoreSimulator runtime, even though they're real host PIDs and
    /// `/usr/bin/sample` finds them fine. (Verified: same PID succeeds with
    /// `sample` and fails with `xctrace --attach <pid>` until --device is added.)
    func start(
        pid: pid_t,
        simulatorUDID: String? = nil,
        maxDurationSec: Int = 600,
        attachTimeoutSec: Double = 8.0
    ) async throws -> Session {
        if let existing = sessions[pid], existing.process.isRunning {
            return existing
        }

        let traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kittyfarm-xctrace-\(pid)-\(UUID().uuidString.prefix(8)).trace")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        var args: [String] = ["xctrace", "record", "--template", "Time Profiler"]
        if let udid = simulatorUDID {
            args.append(contentsOf: ["--device", udid])
        }
        args.append(contentsOf: [
            "--attach", String(pid),
            "--time-limit", "\(maxDurationSec)s",
            "--output", traceURL.path,
            "--no-prompt"
        ])
        process.arguments = args
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.currentDirectoryURL = FileManager.default.temporaryDirectory

        try process.run()
        let session = Session(pid: pid, process: process, traceURL: traceURL, stderrPipe: stderrPipe, stdoutPipe: stdoutPipe)

        // Wait for xctrace to actually attach: either the bundle directory
        // appears (success) or the process exits early (failure with stderr).
        let deadline = Date().addingTimeInterval(attachTimeoutSec)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: traceURL.path) {
                sessions[pid] = session
                return session
            }
            if !process.isRunning {
                let stderr = String(decoding: stderrPipe.fileHandleForReading.availableData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = stderr.isEmpty ? "exit code \(process.terminationStatus)" : stderr
                try? FileManager.default.removeItem(at: traceURL)
                throw XctraceRecorderError.recordingFailed(stderr: detail)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // Timed out: xctrace is still alive but didn't create the bundle. Tear
        // down and surface as a clear error rather than wait forever.
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: traceURL)
        throw XctraceRecorderError.recordingFailed(stderr: "xctrace did not attach within \(Int(attachTimeoutSec))s")
    }

    /// SIGINT the recorder so it flushes its trace, wait for exit, return
    /// the bundle URL. Caller is responsible for parsing/cleanup.
    ///
    /// Hard timeout: xctrace `--device <UDID>` for iOS simulator processes can
    /// hang for several MINUTES after SIGINT in some Xcode/macOS combos
    /// (verified: 254 s flush time for a 15 s recording, then producing an
    /// empty bundle). Don't let the UI lock up — escalate to SIGKILL after
    /// `flushTimeoutSec` and report.
    func stop(_ session: Session, flushTimeoutSec: Double = 30.0) async throws -> URL {
        if session.process.isRunning {
            kill(session.process.processIdentifier, SIGINT)
        }
        let exited = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if !session.process.isRunning {
                        continuation.resume()
                        return
                    }
                    session.process.terminationHandler = { _ in continuation.resume() }
                    if !session.process.isRunning {
                        session.process.terminationHandler = nil
                        continuation.resume()
                    }
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(flushTimeoutSec * 1_000_000_000))
                return false
            }
            let result = await group.next()!
            group.cancelAll()
            return result
        }
        if !exited && session.process.isRunning {
            // Escalate: SIGTERM, then SIGKILL.
            kill(session.process.processIdentifier, SIGTERM)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if session.process.isRunning {
                kill(session.process.processIdentifier, SIGKILL)
            }
        }
        sessions.removeValue(forKey: session.pid)

        guard FileManager.default.fileExists(atPath: session.traceURL.path) else {
            // Drain whatever xctrace told us before exiting so the user can
            // see the real reason in the error UI.
            let stderr = String(decoding: session.stderrPipe.fileHandleForReading.availableData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = String(decoding: session.stdoutPipe.fileHandleForReading.availableData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail: String
            if !stderr.isEmpty { detail = stderr }
            else if !stdout.isEmpty { detail = stdout }
            else { detail = "exit code \(session.process.terminationStatus); no diagnostic output" }
            throw XctraceRecorderError.missingTraceBundle(session.traceURL, detail: detail)
        }
        return session.traceURL
    }

    func cancel(_ session: Session) {
        if session.process.isRunning {
            session.process.terminate()
        }
        sessions.removeValue(forKey: session.pid)
        try? FileManager.default.removeItem(at: session.traceURL)
    }

    func cleanup(_ traceURL: URL) {
        try? FileManager.default.removeItem(at: traceURL)
    }
}

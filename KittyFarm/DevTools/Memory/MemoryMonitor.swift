import Foundation

actor MemoryMonitor {
    typealias SampleHandler = @Sendable (MemorySample) -> Void

    private struct Session {
        let task: Task<Void, Never>
    }

    private var sessions: [String: Session] = [:]

    func start(deviceID: String, pid: pid_t, onSample: @escaping SampleHandler) async {
        if sessions[deviceID] != nil {
            await stop(deviceID: deviceID)
        }

        let task = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if let sample = await Self.captureSample(pid: pid) {
                    onSample(sample)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        sessions[deviceID] = Session(task: task)
    }

    func stop(deviceID: String) async {
        guard let session = sessions.removeValue(forKey: deviceID) else { return }
        session.task.cancel()
    }

    func stopAll() async {
        for session in sessions.values {
            session.task.cancel()
        }
        sessions.removeAll()
    }

    func captureHeap(pid: pid_t) async throws -> String {
        try await captureSnapshot(tool: "heap", pid: pid, timeout: 10)
    }

    func captureVMMap(pid: pid_t) async throws -> String {
        try await captureSnapshot(tool: "vmmap", pid: pid, timeout: 10)
    }

    func captureLeaks(pid: pid_t) async throws -> String {
        try await captureSnapshot(tool: "leaks", pid: pid, timeout: 10, allowNonZeroExit: true)
    }

    private func captureSnapshot(
        tool: String,
        pid: pid_t,
        timeout: TimeInterval,
        allowNonZeroExit: Bool = false
    ) async throws -> String {
        guard let url = Self.resolveBinary(named: tool) else {
            throw MemoryMonitorError.toolNotFound(tool)
        }

        let command = ProcessRunner.Command(
            executableURL: url,
            arguments: ["\(pid)"]
        )

        let timeoutTask: Task<Void, Never> = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        }

        let result = try await withTaskCancellationHandler {
            try await ProcessRunner.run(command)
        } onCancel: {
            timeoutTask.cancel()
        }

        timeoutTask.cancel()

        if !allowNonZeroExit {
            try result.requireSuccess(tool)
        } else if result.terminationStatus != 0, result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try result.requireSuccess(tool)
        }

        return result.stdout
    }

    private static func captureSample(pid: pid_t) async -> MemorySample? {
        if let sample = await captureSampleViaFootprint(pid: pid) {
            return sample
        }
        return await captureSampleViaPs(pid: pid)
    }

    private static func captureSampleViaFootprint(pid: pid_t) async -> MemorySample? {
        guard let url = resolveBinary(named: "footprint") else { return nil }

        do {
            let result = try await ProcessRunner.run(
                ProcessRunner.Command(executableURL: url, arguments: ["\(pid)"])
            )
            guard result.terminationStatus == 0 else { return nil }
            return parseFootprint(result.stdout)
        } catch {
            return nil
        }
    }

    private static func captureSampleViaPs(pid: pid_t) async -> MemorySample? {
        do {
            let result = try await ProcessRunner.run(
                ProcessRunner.Command(
                    executableURL: URL(fileURLWithPath: "/bin/ps"),
                    arguments: ["-p", "\(pid)", "-o", "rss="]
                )
            )
            guard result.terminationStatus == 0 else { return nil }
            let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let rssKB = Double(trimmed) else { return nil }
            let mb = rssKB / 1024.0
            return MemorySample(
                timestamp: Date(),
                footprintMB: mb,
                residentMB: mb,
                dirtyMB: 0
            )
        } catch {
            return nil
        }
    }

    static func parseFootprint(_ text: String) -> MemorySample? {
        var total: Double?
        var resident: Double?
        var dirty: Double?

        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            let lower = line.lowercased()
            let mb = largestMBValue(in: line)
            guard let mb else { continue }

            if total == nil, lower.contains("total") {
                total = mb
            }
            if resident == nil, lower.contains("resident") {
                resident = mb
            }
            if dirty == nil, lower.contains("dirty") {
                dirty = mb
            }
        }

        guard let footprint = total else { return nil }
        return MemorySample(
            timestamp: Date(),
            footprintMB: footprint,
            residentMB: resident ?? footprint,
            dirtyMB: dirty ?? 0
        )
    }

    private static func largestMBValue(in line: String) -> Double? {
        var best: Double?
        let scalars = Array(line)
        var i = 0
        while i < scalars.count {
            guard scalars[i].isNumber else { i += 1; continue }
            var j = i
            while j < scalars.count, scalars[j].isNumber || scalars[j] == "." || scalars[j] == "," {
                j += 1
            }
            let numberText = String(scalars[i..<j]).replacingOccurrences(of: ",", with: "")
            var k = j
            while k < scalars.count, scalars[k] == " " { k += 1 }
            if k + 1 < scalars.count {
                let unit = String(scalars[k..<min(k + 2, scalars.count)]).uppercased()
                if unit == "MB", let value = Double(numberText) {
                    best = max(best ?? 0, value)
                } else if unit == "GB", let value = Double(numberText) {
                    best = max(best ?? 0, value * 1024)
                } else if unit == "KB", let value = Double(numberText) {
                    best = max(best ?? 0, value / 1024)
                }
            }
            i = j + 1
        }
        return best
    }

    private static func resolveBinary(named name: String) -> URL? {
        let candidates = [
            "/usr/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/homebrew/bin/\(name)"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

enum MemoryMonitorError: LocalizedError {
    case toolNotFound(String)

    var errorDescription: String? {
        switch self {
        case let .toolNotFound(name):
            return "\(name) binary not found in /usr/bin or common locations."
        }
    }
}

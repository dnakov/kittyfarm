import Foundation

actor DevToolsSessionManager {
    private struct Session {
        let udid: String
        var bundleID: String?
        var currentPID: pid_t?
        let onMemorySample: (@Sendable (String, MemorySample) -> Void)?
        let onCPUSample: (@Sendable (String, CPUSample) -> Void)?
        let onPIDChange: (@Sendable (String, pid_t?) -> Void)?
        var pollerTask: Task<Void, Never>?
    }

    private var sessions: [String: Session] = [:]
    private let storageInspector = StorageInspector()
    private let memoryMonitor = MemoryMonitor()
    private let cpuMonitor = CPUMonitor()
    private let xctraceRecorder = XctraceRecorder()
    private let networkMonitor = NetworkMonitor.shared

    func start(
        deviceID: String,
        udid: String,
        bundleID: String?,
        onMemorySample: (@Sendable (String, MemorySample) -> Void)? = nil,
        onCPUSample: (@Sendable (String, CPUSample) -> Void)? = nil,
        onPIDChange: (@Sendable (String, pid_t?) -> Void)? = nil,
        onNetworkRequest: (@Sendable (String, NetworkRequest) -> Void)? = nil,
        onNetworkStatus: (@Sendable (String, NetworkStatus) -> Void)? = nil
    ) async {
        sessions[deviceID]?.pollerTask?.cancel()
        await memoryMonitor.stop(deviceID: deviceID)
        await cpuMonitor.stop(deviceID: deviceID)

        var session = Session(
            udid: udid,
            bundleID: bundleID,
            currentPID: nil,
            onMemorySample: onMemorySample,
            onCPUSample: onCPUSample,
            onPIDChange: onPIDChange,
            pollerTask: nil
        )

        let pollerTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.pollPID(deviceID: deviceID)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        session.pollerTask = pollerTask
        sessions[deviceID] = session

        if let onNetworkRequest {
            do {
                try await networkMonitor.start(deviceID: deviceID, udid: udid) { request in
                    onNetworkRequest(deviceID, request)
                }
                onNetworkStatus?(deviceID, .enabled)
            } catch let error as NetworkMonitorError {
                if case .mitmproxyMissing = error {
                    onNetworkStatus?(deviceID, .mitmproxyMissing)
                } else {
                    onNetworkStatus?(deviceID, .failed(error.localizedDescription))
                }
            } catch {
                onNetworkStatus?(deviceID, .failed(error.localizedDescription))
            }
        }

        await pollPID(deviceID: deviceID)
    }

    func stop(deviceID: String) async {
        sessions[deviceID]?.pollerTask?.cancel()
        sessions.removeValue(forKey: deviceID)
        await memoryMonitor.stop(deviceID: deviceID)
        await cpuMonitor.stop(deviceID: deviceID)
        await networkMonitor.stop(deviceID: deviceID)
    }

    func stopAll() async {
        for session in sessions.values {
            session.pollerTask?.cancel()
        }
        sessions.removeAll()
        await memoryMonitor.stopAll()
        await cpuMonitor.stopAll()
        await networkMonitor.stopAll()
    }

    /// Update the bundle ID for a session (e.g., when the user selects a project
    /// after the device was already connected). Triggers an immediate PID re-poll.
    func updateBundleID(deviceID: String, bundleID: String?) async {
        guard var session = sessions[deviceID] else { return }
        session.bundleID = bundleID
        sessions[deviceID] = session
        await pollPID(deviceID: deviceID)
    }

    /// Single poll tick: re-resolves the app PID and starts/stops runtime monitors
    /// when the PID changes (app launched, died, or restarted).
    private func pollPID(deviceID: String) async {
        guard var session = sessions[deviceID] else { return }
        guard let bundleID = session.bundleID, !bundleID.isEmpty else { return }

        let newPID = try? await IOSProcessResolver.resolvePID(udid: session.udid, bundleID: bundleID)
        guard newPID != session.currentPID else { return }

        await memoryMonitor.stop(deviceID: deviceID)
        await cpuMonitor.stop(deviceID: deviceID)

        session.currentPID = newPID
        sessions[deviceID] = session
        session.onPIDChange?(deviceID, newPID)

        guard let pid = newPID else { return }

        if let handler = session.onMemorySample {
            await memoryMonitor.start(deviceID: deviceID, pid: pid) { sample in
                handler(deviceID, sample)
            }
        }
        if let handler = session.onCPUSample {
            await cpuMonitor.start(deviceID: deviceID, pid: pid) { sample in
                handler(deviceID, sample)
            }
        }
    }

    func currentPID(deviceID: String) async -> pid_t? {
        sessions[deviceID]?.currentPID
    }

    func captureDeepSample(pid: pid_t, durationSec: Int) async throws -> String {
        try await cpuMonitor.captureDeepSample(pid: pid, durationSec: durationSec)
    }

    func startDeepSampleRecording(pid: pid_t) async throws -> CPUMonitor.DeepSampleRecording {
        try await cpuMonitor.startDeepSampleRecording(pid: pid)
    }

    func stopDeepSampleRecording(_ recording: CPUMonitor.DeepSampleRecording) async throws -> String {
        try await cpuMonitor.stopDeepSampleRecording(recording)
    }

    func cancelDeepSampleRecording(_ recording: CPUMonitor.DeepSampleRecording) async {
        await cpuMonitor.cancelDeepSampleRecording(recording)
    }

    // MARK: - xctrace (Time Profiler) recording

    func startXctraceRecording(pid: pid_t, simulatorUDID: String?) async throws -> XctraceRecorder.Session {
        try await xctraceRecorder.start(pid: pid, simulatorUDID: simulatorUDID)
    }

    func stopXctraceRecording(
        _ session: XctraceRecorder.Session,
        onFlushComplete: (@Sendable () -> Void)? = nil
    ) async throws -> TimeProfileTrace {
        let traceURL = try await xctraceRecorder.stop(session)
        onFlushComplete?()
        defer { Task { await xctraceRecorder.cleanup(traceURL) } }
        return try await XctraceTimeProfileParser.parse(traceURL: traceURL)
    }

    func cancelXctraceRecording(_ session: XctraceRecorder.Session) async {
        await xctraceRecorder.cancel(session)
    }

    func captureHeap(pid: pid_t) async throws -> String {
        try await memoryMonitor.captureHeap(pid: pid)
    }

    func captureVMMap(pid: pid_t) async throws -> String {
        try await memoryMonitor.captureVMMap(pid: pid)
    }

    func captureLeaks(pid: pid_t) async throws -> String {
        try await memoryMonitor.captureLeaks(pid: pid)
    }

    func refreshStorage(deviceID: String, bundleID: String) async -> StorageSnapshot? {
        guard let session = sessions[deviceID] else { return nil }
        do {
            return try await storageInspector.capture(udid: session.udid, bundleID: bundleID)
        } catch {
            print("DevToolsSessionManager.refreshStorage: \(error.localizedDescription)")
            return nil
        }
    }
}

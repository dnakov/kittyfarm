import AppKit
import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class KittyFarmStore {
    private enum BuildPlatform: String, Sendable {
        case iOS
        case android
    }

    private struct BuildPlatformResult: Sendable {
        let platform: BuildPlatform
        let summary: String
        let runtimeTargets: [RuntimeLogTarget]
        let errorMessage: String?
    }

    var availableDevices: [DeviceDescriptor] = []
    var activeDevices: [DeviceState] = []
    var leaderID: String?
    var activeInputDeviceID: String?
    var syncEnabled = true
    var isPresentingDevicePicker = false
    var isPresentingProjectPicker = false
    var isRunningBuildAndPlay = false
    var bottomPanel: BottomPanel = .hidden
    var statusMessage = "Add an iOS simulator or Android emulator to begin."
    var deviceBootStates: [String: String] = [:]
    var selectedIOSProject: IOSProjectConfiguration?
    var selectedAndroidProject: AndroidProjectConfiguration?
    var selectedBuildLogFilterID = BuildLogFilter.all.id
    var buildLogs: [BuildLogEntry] = []
    var filteredBuildLogs: [BuildLogEntry] = []
    var buildWarningCount = 0
    var buildErrorCount = 0

    // Testing
    var testScript: String = UserDefaults.standard.string(forKey: "KittyFarm.testScript") ?? ""
    var testTargetBundleID: String = UserDefaults.standard.string(forKey: "KittyFarm.testTargetBundleID") ?? ""
    var isRunningTest = false
    var testResults: [TestStepResult] = []
    var testStatusMessage: String?

    private let simctlManager = SimctlManager()
    private let emulatorManager = EmulatorManager()
    private let inputCoordinator = InputCoordinator()
    private let runtimeLogManager = RuntimeLogStreamManager()
    private let devToolsSessions = DevToolsSessionManager()
    private var connections: [String: AnyDeviceConnectionBox] = [:]
    private let testRunner = TestRunner()

    private static let savedDevicesKey = "KittyFarm.savedDevices"
    private static let savedLeaderKey = "KittyFarm.leaderID"
    private static let savedIOSProjectKey = "KittyFarm.selectedIOSProject"
    private static let savedAndroidProjectKey = "KittyFarm.selectedAndroidProject"
    private static let maxBuildLogEntries = 10000

    init() {
        Task.detached { await ProxyConfigurer.shared.cleanupStale() }
    }

    // MARK: - Discovery

    func refreshAvailableDevices() async {
        do {
            async let simulators = simctlManager.listDevices()
            async let emulators = emulatorManager.listAVDs()

            let simResults = try await simulators
            let emuResults = try await emulators

            var states: [String: String] = [:]
            var descriptors: [DeviceDescriptor] = []

            for info in simResults {
                descriptors.append(info.descriptor)
                states[info.descriptor.id] = info.bootState
            }
            for descriptor in emuResults {
                descriptors.append(descriptor)
            }

            availableDevices = descriptors.sorted { lhs, rhs in
                if lhs.platform == rhs.platform {
                    return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                }
                return lhs.platform.rawValue < rhs.platform.rawValue
            }
            deviceBootStates = states
            statusMessage = availableDevices.isEmpty ? "No simulators or AVDs were discovered." : "Choose devices to populate the grid."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    // MARK: - Persistence

    func restoreSavedProjects() {
        let defaults = UserDefaults.standard

        if let data = defaults.data(forKey: Self.savedIOSProjectKey),
           let project = try? JSONDecoder().decode(IOSProjectConfiguration.self, from: data) {
            selectedIOSProject = project

            // Backfill bundle identifier for projects saved before we started capturing it
            if project.bundleIdentifier == nil {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let updated = try? await BuildPlayRunner.discoverIOSProject(at: project.projectURL),
                       updated.bundleIdentifier != nil {
                        self.selectedIOSProject = IOSProjectConfiguration(
                            projectPath: project.projectPath,
                            scheme: project.scheme,
                            bundleIdentifier: updated.bundleIdentifier
                        )
                        self.persistSelectedProjects()
                    }
                }
            }
        }

        if let data = defaults.data(forKey: Self.savedAndroidProjectKey),
           let project = try? JSONDecoder().decode(AndroidProjectConfiguration.self, from: data) {
            selectedAndroidProject = project
        }

    }

    func restoreSavedDevices() async {
        let saved = Self.loadSavedDevices()
        guard !saved.isEmpty else { return }

        let availableByID = Dictionary(uniqueKeysWithValues: availableDevices.map { ($0.id, $0) })

        // Register all devices first (sync, shows them in the grid immediately)
        var toConnect: [(DeviceDescriptor, DeviceState)] = []
        for descriptor in saved {
            if let available = availableByID[descriptor.id] {
                let state = registerDevice(available)
                toConnect.append((available, state))
            }
        }

        if let savedLeader = UserDefaults.standard.string(forKey: Self.savedLeaderKey),
           activeDevices.contains(where: { $0.id == savedLeader }) {
            leaderID = savedLeader
        }

        saveDeviceOrder()

        // Connect all devices in parallel
        await withTaskGroup(of: Void.self) { group in
            for (descriptor, state) in toConnect {
                group.addTask {
                    await self.connectDevice(descriptor, state: state)
                }
            }
        }
    }

    func selectIOSProject(at url: URL) async {
        do {
            let project = try await BuildPlayRunner.discoverIOSProject(at: url)
            selectedIOSProject = project
            persistSelectedProjects()
            statusMessage = "Selected iOS project \(project.displayName)."
            for device in activeDevices where device.descriptor.platform == .iOSSimulator {
                await devToolsSessions.updateBundleID(deviceID: device.id, bundleID: project.bundleIdentifier)
            }
        } catch {
            statusMessage = "Failed to configure iOS project: \(error.localizedDescription)"
        }
    }

    func clearIOSProject() {
        selectedIOSProject = nil
        persistSelectedProjects()
        statusMessage = "Cleared the iOS project."
    }

    func updateIOSScheme(_ scheme: String) {
        guard var project = selectedIOSProject else { return }
        project.scheme = scheme.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedIOSProject = project
        persistSelectedProjects()
    }

    func selectAndroidProject(at url: URL) async {
        do {
            let project = try await BuildPlayRunner.discoverAndroidProject(at: url)
            selectedAndroidProject = project
            persistSelectedProjects()
            statusMessage = "Selected Android project \(project.displayName)."
        } catch {
            statusMessage = "Failed to configure Android project: \(error.localizedDescription)"
        }
    }

    func clearAndroidProject() {
        selectedAndroidProject = nil
        persistSelectedProjects()
        statusMessage = "Cleared the Android project."
    }

    func updateAndroidApplicationID(_ applicationID: String) {
        guard var project = selectedAndroidProject else { return }
        project.applicationID = applicationID.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedAndroidProject = project
        persistSelectedProjects()
    }

    func updateAndroidGradleTask(_ task: String) {
        guard var project = selectedAndroidProject else { return }
        project.gradleTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedAndroidProject = project
        persistSelectedProjects()
    }

    func clearBuildLogs() {
        buildLogs.removeAll()
        filteredBuildLogs.removeAll()
        buildWarningCount = 0
        buildErrorCount = 0
        selectedBuildLogFilterID = BuildLogFilter.all.id
    }

    func toggleBuildLogs() {
        bottomPanel = (bottomPanel == .logs) ? .hidden : .logs
    }

    func toggleTestPanel() {
        bottomPanel = (bottomPanel == .tests) ? .hidden : .tests
    }

    func showBottomPanel(_ panel: BottomPanel) {
        bottomPanel = panel
    }

    // MARK: - Memory Snapshots

    func captureHeapSnapshot(pid: pid_t) async throws -> String {
        try await devToolsSessions.captureHeap(pid: pid)
    }

    func captureVMMapSnapshot(pid: pid_t) async throws -> String {
        try await devToolsSessions.captureVMMap(pid: pid)
    }

    func captureLeaksSnapshot(pid: pid_t) async throws -> String {
        try await devToolsSessions.captureLeaks(pid: pid)
    }

    // MARK: - CPU Deep Sample

    func captureDeepSample(pid: pid_t, durationSec: Int = 10) async throws -> String {
        try await devToolsSessions.captureDeepSample(pid: pid, durationSec: durationSec)
    }

    func startDeepSampleRecording(pid: pid_t) async throws -> CPUMonitor.DeepSampleRecording {
        try await devToolsSessions.startDeepSampleRecording(pid: pid)
    }

    func stopDeepSampleRecording(_ recording: CPUMonitor.DeepSampleRecording) async throws -> String {
        try await devToolsSessions.stopDeepSampleRecording(recording)
    }

    func cancelDeepSampleRecording(_ recording: CPUMonitor.DeepSampleRecording) async {
        await devToolsSessions.cancelDeepSampleRecording(recording)
    }

    // MARK: - Time Profiler (xctrace)

    func startXctraceRecording(pid: pid_t, simulatorUDID: String?) async throws -> XctraceRecorder.Session {
        try await devToolsSessions.startXctraceRecording(pid: pid, simulatorUDID: simulatorUDID)
    }

    func stopXctraceRecording(
        _ session: XctraceRecorder.Session,
        onFlushComplete: (@Sendable () -> Void)? = nil
    ) async throws -> TimeProfileTrace {
        try await devToolsSessions.stopXctraceRecording(session, onFlushComplete: onFlushComplete)
    }

    func cancelXctraceRecording(_ session: XctraceRecorder.Session) async {
        await devToolsSessions.cancelXctraceRecording(session)
    }

    // MARK: - Device Management

    func addDevice(_ descriptor: DeviceDescriptor, persist: Bool = true) async {
        let state = registerDevice(descriptor)
        if persist {
            saveDeviceOrder()
        }
        await connectDevice(descriptor, state: state)
    }

    /// Register a device in the UI (sync). Returns the new DeviceState.
    @discardableResult
    private func registerDevice(_ descriptor: DeviceDescriptor) -> DeviceState {
        guard connections[descriptor.id] == nil else {
            return activeDevices.first { $0.id == descriptor.id }!
        }

        let state = DeviceState(descriptor: descriptor)
        state.isConnecting = true
        activeDevices.append(state)

        if leaderID == nil {
            leaderID = state.id
        }
        if activeInputDeviceID == nil {
            activeInputDeviceID = state.id
        }

        return state
    }

    /// Connect a device (async). Can be called in parallel for multiple devices.
    private func connectDevice(_ descriptor: DeviceDescriptor, state: DeviceState) async {
        do {
            let connection = try await makeConnection(for: descriptor, state: state)
            let box = AnyDeviceConnectionBox(connection)
            connections[descriptor.id] = box
            try await box.connect()
            state.noteConnected()
            await attachDevTools(to: state)
            statusMessage = "Connected \(descriptor.displayName)."
        } catch {
            state.noteError(error)
            statusMessage = "Failed to connect \(descriptor.displayName): \(error.localizedDescription)"
        }
    }

    /// Attach DevTools monitors for an iOS device. Starts the network monitor unconditionally
    /// (needs only UDID) and kicks off the PID poller that auto-attaches memory/CPU monitors
    /// whenever the target app appears (via Build & Play, Xcode, or any other launch path).
    /// Re-callable — existing session is torn down and restarted.
    private func attachDevTools(to state: DeviceState) async {
        guard case let .iOSSimulator(udid, _, _) = state.descriptor else { return }
        let bundleID = selectedIOSProject?.bundleIdentifier

        await devToolsSessions.start(
            deviceID: state.id,
            udid: udid,
            bundleID: bundleID,
            onMemorySample: Self.memorySampleHandler(for: self),
            onCPUSample: Self.cpuSampleHandler(for: self),
            onPIDChange: Self.pidChangeHandler(for: self),
            onNetworkRequest: Self.networkRequestHandler(for: self),
            onNetworkStatus: Self.networkStatusHandler(for: self)
        )
    }

    private static func pidChangeHandler(for store: KittyFarmStore) -> @Sendable (String, pid_t?) -> Void {
        { [weak store] deviceID, pid in
            Task { @MainActor [weak store] in
                store?.activeDevices.first { $0.id == deviceID }?.currentPID = pid
            }
        }
    }

    private static func memorySampleHandler(for store: KittyFarmStore) -> @Sendable (String, MemorySample) -> Void {
        { [weak store] deviceID, sample in
            Task { @MainActor [weak store] in
                store?.activeDevices.first { $0.id == deviceID }?.appendMemorySample(sample)
            }
        }
    }

    private static func cpuSampleHandler(for store: KittyFarmStore) -> @Sendable (String, CPUSample) -> Void {
        { [weak store] deviceID, sample in
            Task { @MainActor [weak store] in
                store?.activeDevices.first { $0.id == deviceID }?.appendCPUSample(sample)
            }
        }
    }

    private static func networkRequestHandler(for store: KittyFarmStore) -> @Sendable (String, NetworkRequest) -> Void {
        { [weak store] deviceID, request in
            Task { @MainActor [weak store] in
                store?.activeDevices.first { $0.id == deviceID }?.appendNetworkRequest(request)
            }
        }
    }

    private static func networkStatusHandler(for store: KittyFarmStore) -> @Sendable (String, NetworkStatus) -> Void {
        { [weak store] deviceID, status in
            Task { @MainActor [weak store] in
                store?.activeDevices.first { $0.id == deviceID }?.updateNetworkStatus(status)
            }
        }
    }

    func removeDevice(_ state: DeviceState) async {
        let connection = connections.removeValue(forKey: state.id)
        activeDevices.removeAll { $0.id == state.id }
        if leaderID == state.id {
            leaderID = activeDevices.first?.id
        }
        if activeInputDeviceID == state.id {
            activeInputDeviceID = activeDevices.first?.id
        }
        saveDeviceOrder()
        await devToolsSessions.stop(deviceID: state.id)
        await connection?.disconnect()
    }

    func setLeader(_ state: DeviceState) {
        leaderID = state.id
        saveDeviceOrder()
    }

    func setActiveInputDevice(_ state: DeviceState) {
        activeInputDeviceID = state.id
    }

    func pressHomeButton(on state: DeviceState) async {
        guard let connection = connections[state.id] else {
            return
        }

        do {
            try await connection.pressHomeButton()
            statusMessage = "Pressed Home on \(state.descriptor.displayName)."
        } catch {
            state.noteError(error)
            statusMessage = "Failed to press Home on \(state.descriptor.displayName): \(error.localizedDescription)"
        }
    }

    func triggerSimulatorControl(_ control: SimulatorChromeControl, on state: DeviceState) async {
        guard let connection = connections[state.id] else {
            return
        }

        do {
            try await connection.triggerSimulatorControl(control.id)
            statusMessage = "Triggered \(control.displayName) on \(state.descriptor.displayName)."
        } catch {
            state.noteError(error)
            statusMessage = "Failed to trigger \(control.displayName) on \(state.descriptor.displayName): \(error.localizedDescription)"
        }
    }

    func rotateDeviceRight(on state: DeviceState) async {
        guard let connection = connections[state.id] else {
            return
        }

        do {
            try await connection.rotateRight()
            statusMessage = "Rotated \(state.descriptor.displayName)."
        } catch {
            state.noteError(error)
            statusMessage = "Failed to rotate \(state.descriptor.displayName): \(error.localizedDescription)"
        }
    }

    func handleHardwareKeyboardEvent(_ event: NSEvent) -> Bool {
        guard let activeInputDeviceID,
              let state = activeDevices.first(where: { $0.id == activeInputDeviceID }),
              let connection = connections[activeInputDeviceID] else {
            return false
        }

        if NSApp.keyWindow?.firstResponder is NSTextView {
            return false
        }

        if event.modifierFlags.contains(.command),
           event.type == .keyDown,
           event.charactersIgnoringModifiers?.lowercased() == "v",
           let string = NSPasteboard.general.string(forType: .string),
           !string.isEmpty {
            Task {
                await replicatePasteboard(from: state, text: string)
                do {
                    try await connection.sendHardwareKeyboardEvent(event)
                } catch {
                    print("KittyFarmStore hardware keyboard error [\(state.descriptor.displayName)]: \(error.localizedDescription)")
                }
            }
            return true
        }

        Task {
            do {
                try await connection.sendHardwareKeyboardEvent(event)
            } catch {
                print("KittyFarmStore hardware keyboard error [\(state.descriptor.displayName)]: \(error.localizedDescription)")
            }
        }
        return true
    }

    func applySelection(_ selectedIDs: Set<String>) async {
        let currentIDs = Set(activeDevices.map(\.id))

        let toRemove = activeDevices.filter { !selectedIDs.contains($0.id) }
        for device in toRemove {
            await removeDevice(device)
        }

        let toAdd = availableDevices.filter { selectedIDs.contains($0.id) && !currentIDs.contains($0.id) }
        await withTaskGroup(of: Void.self) { group in
            for descriptor in toAdd {
                group.addTask {
                    await self.addDevice(descriptor)
                }
            }
        }

        isPresentingDevicePicker = false
    }

    // MARK: - Reordering

    func moveDevice(_ sourceID: String, before targetID: String) {
        guard let sourceIndex = activeDevices.firstIndex(where: { $0.id == sourceID }),
              activeDevices.contains(where: { $0.id == targetID }),
              sourceIndex != activeDevices.firstIndex(where: { $0.id == targetID })
        else { return }

        let device = activeDevices.remove(at: sourceIndex)
        if let newTarget = activeDevices.firstIndex(where: { $0.id == targetID }) {
            activeDevices.insert(device, at: newTarget)
        } else {
            activeDevices.append(device)
        }
        saveDeviceOrder()
    }

    // MARK: - Shutdown

    func shutdownAllSimulators() async {
        // Disconnect our iOS devices first
        let iosDevices = activeDevices.filter { $0.descriptor.platform == .iOSSimulator }
        for device in iosDevices {
            await removeDevice(device)
        }
        // Then shut down all simulators system-wide
        do {
            _ = try await ProcessRunner.run(XcrunUtils.simctl(["shutdown", "all"]))
            statusMessage = "All iOS simulators shut down."
        } catch {
            statusMessage = "Failed to shutdown simulators: \(error.localizedDescription)"
        }
    }

    func killAllEmulators() async {
        // Disconnect our Android devices first
        let androidDevices = activeDevices.filter { $0.descriptor.platform == .androidEmulator }
        for device in androidDevices {
            await removeDevice(device)
        }
        // Kill all emulator processes
        do {
            _ = try await ProcessRunner.run(.init(
                executableURL: URL(fileURLWithPath: "/usr/bin/killall"),
                arguments: ["qemu-system-aarch64"]
            ))
            statusMessage = "All Android emulators killed."
        } catch {
            // killall returns error if no processes found — that's fine
            statusMessage = "Android emulators stopped."
        }
    }

    func shutdownAll() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.shutdownAllSimulators() }
            group.addTask { await self.killAllEmulators() }
        }
        statusMessage = "All simulators and emulators shut down."
    }

    // MARK: - Touch Replication

    func replicateTouch(from state: DeviceState, location: CGPoint, in size: CGSize, phase: NormalizedTouch.Phase) async {
        guard size.width > 0, size.height > 0 else {
            return
        }

        let normalizedX = location.x / size.width
        let normalizedY = location.y / size.height
        let normalizedTouch = NormalizedTouch(
            nx: normalizedX,
            ny: normalizedY,
            phase: phase,
            pressure: 1,
            id: 0
        )

        let targets = [connections[state.id]].compactMap { $0 }
        await inputCoordinator.replicate(normalizedTouch, to: targets)
    }

    func replicateKey(from state: DeviceState, event: DeviceKeyboardEvent) async {
        let targets = [connections[state.id]].compactMap { $0 }
        await inputCoordinator.replicate(event, to: targets)
    }

    func replicatePasteboard(from state: DeviceState, text: String) async {
        let targets = [connections[state.id]].compactMap { $0 }
        await inputCoordinator.replicatePasteboard(text, to: targets)
    }
    // MARK: - Build & Play

    func buildAndPlay() async {
        guard !isRunningBuildAndPlay else {
            return
        }

        let iosDevices = activeDevices.map(\.descriptor).filter { $0.platform == .iOSSimulator }
        let androidDevices = activeDevices.map(\.descriptor).filter { $0.platform == .androidEmulator }

        guard !iosDevices.isEmpty || !androidDevices.isEmpty else {
            statusMessage = "Add at least one simulator or emulator before building."
            return
        }

        if !iosDevices.isEmpty, selectedIOSProject == nil {
            statusMessage = "Choose an iOS project before building for iOS simulators."
            return
        }

        if !androidDevices.isEmpty, selectedAndroidProject == nil {
            statusMessage = "Choose an Android project before building for Android emulators."
            return
        }

        beginBuildLogSession()
        await runtimeLogManager.stopAll()
        isRunningBuildAndPlay = true

        for device in activeDevices {
            device.isBuildingApp = true
        }
        var successes: [String] = []
        var failures: [String] = []
        var runtimeTargets: [RuntimeLogTarget] = []

        defer {
            isRunningBuildAndPlay = false
            for device in activeDevices {
                device.isBuildingApp = false
            }

            if failures.isEmpty {
                statusMessage = successes.isEmpty
                    ? "Nothing was built."
                    : "Build & Play finished: \(successes.joined(separator: " • "))"
            } else if successes.isEmpty {
                statusMessage = failures.joined(separator: " • ")
            } else {
                statusMessage = "\(successes.joined(separator: " • ")) • \(failures.joined(separator: " • "))"
            }
        }

        if let project = selectedIOSProject, !iosDevices.isEmpty,
           let androidProject = selectedAndroidProject, !androidDevices.isEmpty {
            statusMessage = "Building \(project.displayName) and \(androidProject.displayName) in parallel…"
        } else if let project = selectedIOSProject, !iosDevices.isEmpty {
            statusMessage = "Building \(project.displayName) for \(iosDevices.count) iOS simulator(s)…"
        } else if let project = selectedAndroidProject, !androidDevices.isEmpty {
            statusMessage = "Building \(project.displayName) for \(androidDevices.count) Android emulator(s)…"
        }

        if let project = selectedIOSProject, !iosDevices.isEmpty {
            appendBuildLog(
                "Building \(project.displayName) for \(iosDevices.count) iOS simulator(s)",
                source: .system
            )
        }

        if let project = selectedAndroidProject, !androidDevices.isEmpty {
            appendBuildLog(
                "Building \(project.displayName) for \(androidDevices.count) Android emulator(s)",
                source: .system
            )
        }

        let logger: BuildPlayRunner.Logger = { [weak self] source, message in
            self?.queueBuildLog(source: source, message: message)
        }

        var resultsByPlatform: [BuildPlatform: BuildPlatformResult] = [:]

        await withTaskGroup(of: BuildPlatformResult.self) { group in
            if let project = selectedIOSProject, !iosDevices.isEmpty {
                group.addTask {
                    do {
                        let result = try await BuildPlayRunner.buildAndRunIOS(
                            project: project,
                            devices: iosDevices,
                            logger: logger
                        )
                        return BuildPlatformResult(
                            platform: .iOS,
                            summary: "iOS launched on \(result.launchedDeviceCount) simulator(s)",
                            runtimeTargets: result.runtimeTargets,
                            errorMessage: nil
                        )
                    } catch {
                        return BuildPlatformResult(
                            platform: .iOS,
                            summary: "",
                            runtimeTargets: [],
                            errorMessage: "iOS failed: \(error.localizedDescription)"
                        )
                    }
                }
            }

            if let project = selectedAndroidProject, !androidDevices.isEmpty {
                group.addTask {
                    do {
                        let result = try await BuildPlayRunner.buildAndRunAndroid(
                            project: project,
                            devices: androidDevices,
                            logger: logger
                        )
                        return BuildPlatformResult(
                            platform: .android,
                            summary: "Android launched on \(result.launchedDeviceCount) emulator(s)",
                            runtimeTargets: result.runtimeTargets,
                            errorMessage: nil
                        )
                    } catch {
                        return BuildPlatformResult(
                            platform: .android,
                            summary: "",
                            runtimeTargets: [],
                            errorMessage: "Android failed: \(error.localizedDescription)"
                        )
                    }
                }
            }

            for await result in group {
                resultsByPlatform[result.platform] = result
            }
        }

        for platform in [BuildPlatform.iOS, .android] {
            guard let result = resultsByPlatform[platform] else { continue }

            if let errorMessage = result.errorMessage {
                appendBuildLog(errorMessage, source: .system, severity: .error)
                failures.append(errorMessage)
                continue
            }

            runtimeTargets.append(contentsOf: result.runtimeTargets)
            successes.append(result.summary)
            appendBuildLog(result.summary, source: .system)
        }

        if !runtimeTargets.isEmpty {
            appendBuildLog("Starting runtime log streams", source: .system)
            await runtimeLogManager.replaceStreams(for: runtimeTargets) { [weak self] source, message in
                self?.queueBuildLog(source: source, message: message)
            }
        }
    }

    func buildAndPlay(for device: DeviceState) async {
        guard !isRunningBuildAndPlay else { return }

        let descriptor = device.descriptor
        let iosDevices = descriptor.platform == .iOSSimulator ? [descriptor] : []
        let androidDevices = descriptor.platform == .androidEmulator ? [descriptor] : []

        if !iosDevices.isEmpty, selectedIOSProject == nil {
            statusMessage = "Choose an iOS project before building."
            return
        }
        if !androidDevices.isEmpty, selectedAndroidProject == nil {
            statusMessage = "Choose an Android project before building."
            return
        }

        beginBuildLogSession()
        isRunningBuildAndPlay = true
        device.isBuildingApp = true

        defer {
            isRunningBuildAndPlay = false
            device.isBuildingApp = false
        }

        let logger: BuildPlayRunner.Logger = { [weak self] source, message in
            self?.queueBuildLog(source: source, message: message)
        }

        if let project = selectedIOSProject, !iosDevices.isEmpty {
            statusMessage = "Building \(project.displayName) for \(descriptor.displayName)…"
            appendBuildLog("Building \(project.displayName) for \(descriptor.displayName)", source: .system)
            do {
                let result = try await BuildPlayRunner.buildAndRunIOS(
                    project: project, devices: iosDevices, logger: logger
                )
                let summary = "iOS launched on \(descriptor.displayName)"
                appendBuildLog(summary, source: .system)
                statusMessage = summary

                if !result.runtimeTargets.isEmpty {
                    await runtimeLogManager.replaceStreams(for: result.runtimeTargets) { [weak self] source, message in
                        self?.queueBuildLog(source: source, message: message)
                    }
                }
            } catch {
                let msg = "iOS failed: \(error.localizedDescription)"
                appendBuildLog(msg, source: .system, severity: .error)
                statusMessage = msg
            }
        }

        if let project = selectedAndroidProject, !androidDevices.isEmpty {
            statusMessage = "Building \(project.displayName) for \(descriptor.displayName)…"
            appendBuildLog("Building \(project.displayName) for \(descriptor.displayName)", source: .system)
            do {
                let result = try await BuildPlayRunner.buildAndRunAndroid(
                    project: project, devices: androidDevices, logger: logger
                )
                let summary = "Android launched on \(descriptor.displayName)"
                appendBuildLog(summary, source: .system)
                statusMessage = summary

                if !result.runtimeTargets.isEmpty {
                    await runtimeLogManager.replaceStreams(for: result.runtimeTargets) { [weak self] source, message in
                        self?.queueBuildLog(source: source, message: message)
                    }
                }
            } catch {
                let msg = "Android failed: \(error.localizedDescription)"
                appendBuildLog(msg, source: .system, severity: .error)
                statusMessage = msg
            }
        }
    }

    private func rebuildLogCaches() {
        buildWarningCount = buildLogs.reduce(into: 0) { c, e in if e.severity == .warning { c += 1 } }
        buildErrorCount = buildLogs.reduce(into: 0) { c, e in if e.severity == .error { c += 1 } }
        rebuildFilteredLogs()
    }

    private func rebuildFilteredLogs() {
        if selectedBuildLogFilterID == BuildLogFilter.all.id {
            filteredBuildLogs = buildLogs
        } else {
            filteredBuildLogs = buildLogs.filter { $0.scope.id == selectedBuildLogFilterID }
        }
    }

    var shouldShowBuildLogs: Bool {
        bottomPanel == .logs && (!buildLogs.isEmpty || isRunningBuildAndPlay)
    }

    var shouldShowBottomPanel: Bool {
        bottomPanel != .hidden
    }

    /// Device targeted by the DevTools bottom-panel tabs.
    /// Prefers the leader if it's an iOS sim, else the first iOS sim in the grid.
    /// Returns nil when no iOS sim is active — DevTools panels are iOS-only for now.
    var focusedIOSDevice: DeviceState? {
        if let leaderID,
           let leader = activeDevices.first(where: { $0.id == leaderID }),
           leader.descriptor.platform == .iOSSimulator {
            return leader
        }
        return activeDevices.first { $0.descriptor.platform == .iOSSimulator }
    }

    var networkRequestCount: Int {
        activeDevices.reduce(0) { $0 + $1.networkRequests.count }
    }

    func clearNetworkRequests() {
        for device in activeDevices {
            device.clearNetworkRequests()
        }
    }

    var buildSummaryText: String {
        if let error = buildLogs.last(where: { $0.severity == .error })?.message {
            return error
        }

        if let warning = buildLogs.last(where: { $0.severity == .warning })?.message {
            return warning
        }

        if let lastSystemMessage = buildLogs.last(where: { $0.source == .system })?.message {
            return lastSystemMessage
        }

        return statusMessage
    }

    var availableBuildLogFilters: [BuildLogFilter] {
        var filters: [BuildLogFilter] = [.all]
        let scopes = Array(Set(buildLogs.map(\.scope)))
            .sorted { lhs, rhs in
                if lhs.id == BuildLogScope.build.id { return true }
                if rhs.id == BuildLogScope.build.id { return false }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }

        filters.append(contentsOf: scopes.map { BuildLogFilter(id: $0.id, title: $0.title) })
        return filters
    }

    func selectBuildLogFilter(_ filter: BuildLogFilter) {
        selectedBuildLogFilterID = filter.id
        rebuildFilteredLogs()
    }

    // MARK: - DevTools

    func refreshStorage(for state: DeviceState) async {
        guard state.descriptor.platform == .iOSSimulator,
              let bundleID = selectedIOSProject?.bundleIdentifier
        else { return }

        state.isRefreshingStorage = true
        let snapshot = await devToolsSessions.refreshStorage(deviceID: state.id, bundleID: bundleID)
        state.storageSnapshot = snapshot
        state.isRefreshingStorage = false
    }

    // MARK: - Testing

    func runTestScript() async {
        guard !isRunningTest, !activeDevices.isEmpty else { return }

        let script: [TestAction]
        do {
            script = try TestScriptParser.parse(testScript)
        } catch {
            testStatusMessage = error.localizedDescription
            return
        }

        guard !script.isEmpty else {
            testStatusMessage = "Script is empty."
            return
        }

        isRunningTest = true
        testResults = []
        testStatusMessage = "Running \(script.count) steps..."
        UserDefaults.standard.set(testScript, forKey: "KittyFarm.testScript")
        UserDefaults.standard.set(testTargetBundleID, forKey: "KittyFarm.testTargetBundleID")

        // Capture everything needed from @MainActor before entering task group
        struct DeviceTestContext: Sendable {
            let connection: AnyDeviceConnectionBox
            let provider: any AccessibilityTreeProvider
            let deviceName: String
        }

        let bundleID = testTargetBundleID.isEmpty ? nil : testTargetBundleID
        var contexts: [DeviceTestContext] = []
        for deviceState in activeDevices {
            guard let connection = connections[deviceState.id] else { continue }
            let provider = makeTreeProvider(for: deviceState, bundleID: bundleID)
            contexts.append(DeviceTestContext(
                connection: connection,
                provider: provider,
                deviceName: deviceState.descriptor.displayName
            ))
        }

        // Run on all devices in parallel
        let runner = testRunner
        let resultCollector = TestResultCollector()

        await withTaskGroup(of: (String, TestRunResult).self) { group in
            for ctx in contexts {
                group.addTask {
                    let result = await runner.run(
                        script: script,
                        connection: ctx.connection,
                        treeProvider: ctx.provider
                    ) { step in
                        await resultCollector.append(step)
                    }
                    return (ctx.deviceName, result)
                }
            }

            for await (deviceName, result) in group {
                let steps = await resultCollector.drain()
                testResults.append(contentsOf: steps)
                if result.passed {
                    testStatusMessage = "\(deviceName): All \(result.passedCount) steps passed"
                } else {
                    testStatusMessage = "\(deviceName): \(result.failedCount) failed, \(result.passedCount) passed"
                }
            }
        }

        isRunningTest = false
    }

    private func makeTreeProvider(for state: DeviceState, bundleID: String?) -> any AccessibilityTreeProvider {
        let descriptor = state.descriptor
        let size = state.currentFrame?.dimensions
        switch descriptor {
        case let .iOSSimulator(udid, _, _):
            let width = Double(size?.width ?? 390)
            let height = Double(size?.height ?? 844)
            return IOSAccessibilityProvider(udid: udid, screenWidth: width, screenHeight: height, bundleIdentifier: bundleID)

        case let .androidEmulator(avdName, _):
            let width = Double(size?.width ?? 1080)
            let height = Double(size?.height ?? 2400)
            return LazyAndroidAccessibilityProvider(avdName: avdName, screenWidth: width, screenHeight: height)
        }
    }

    // MARK: - Private

    private func makeConnection(for descriptor: DeviceDescriptor, state: DeviceState) async throws -> any DeviceConnection {
        switch descriptor {
        case .iOSSimulator:
            try await simctlManager.ensureSimulatorReady(descriptor)
            return try IOSSimulatorConnection(descriptor: descriptor, state: state)
        case let .androidEmulator(avdName, grpcPort):
            try await emulatorManager.launchIfNeeded(avdName: avdName, grpcPort: grpcPort)
            return AndroidEmulatorConnection(descriptor: descriptor, state: state)
        }
    }

    private func saveDeviceOrder() {
        let descriptors = activeDevices.map(\.descriptor)
        if let data = try? JSONEncoder().encode(descriptors) {
            UserDefaults.standard.set(data, forKey: Self.savedDevicesKey)
        }
        if let leader = leaderID {
            UserDefaults.standard.set(leader, forKey: Self.savedLeaderKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.savedLeaderKey)
        }
    }

    private func persistSelectedProjects() {
        let defaults = UserDefaults.standard

        if let selectedIOSProject,
           let data = try? JSONEncoder().encode(selectedIOSProject) {
            defaults.set(data, forKey: Self.savedIOSProjectKey)
        } else {
            defaults.removeObject(forKey: Self.savedIOSProjectKey)
        }

        if let selectedAndroidProject,
           let data = try? JSONEncoder().encode(selectedAndroidProject) {
            defaults.set(data, forKey: Self.savedAndroidProjectKey)
        } else {
            defaults.removeObject(forKey: Self.savedAndroidProjectKey)
        }
    }

    private func appendBuildLog(
        _ message: String,
        source: BuildLogSource,
        severity: BuildLogSeverity? = nil
    ) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let entry = BuildLogEntry(
            source: source,
            severity: severity ?? inferredSeverity(for: trimmed, source: source),
            scope: scope(for: trimmed),
            message: trimmed
        )

        buildLogs.append(entry)

        switch entry.severity {
        case .warning: buildWarningCount += 1
        case .error: buildErrorCount += 1
        case .info: break
        }

        if selectedBuildLogFilterID == BuildLogFilter.all.id || entry.scope.id == selectedBuildLogFilterID {
            filteredBuildLogs.append(entry)
        }

        // Trim old entries in bulk (only when 10% over, to avoid per-entry churn)
        let trimThreshold = Self.maxBuildLogEntries + Self.maxBuildLogEntries / 10
        if buildLogs.count > trimThreshold {
            let excess = buildLogs.count - Self.maxBuildLogEntries
            for i in 0..<excess {
                switch buildLogs[i].severity {
                case .warning: buildWarningCount = max(buildWarningCount - 1, 0)
                case .error: buildErrorCount = max(buildErrorCount - 1, 0)
                case .info: break
                }
            }
            buildLogs.removeFirst(excess)
            rebuildFilteredLogs()
        }
    }

    private func beginBuildLogSession() {
        selectedBuildLogFilterID = BuildLogFilter.all.id

        // Auto-switch to logs panel when a build starts, unless the user is viewing another panel
        if bottomPanel == .hidden {
            bottomPanel = .logs
        }

        if !buildLogs.isEmpty {
            appendBuildLog(String(repeating: "=", count: 48), source: .system)
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        appendBuildLog("Starting Build & Play at \(formatter.string(from: Date()))", source: .system)
    }

    nonisolated private func queueBuildLog(source: BuildLogSource, message: String) {
        Task { @MainActor [weak self] in
            self?.appendBuildLog(message, source: source)
        }
    }

    private func inferredSeverity(for message: String, source: BuildLogSource) -> BuildLogSeverity {
        let lowered = message.localizedLowercase

        if lowered.contains(" error:")
            || lowered.hasPrefix("error:")
            || lowered.contains(": error:")
            || lowered.contains(" failed with exit code")
            || lowered.hasPrefix("fatal:")
            || lowered == "failed"
        {
            return .error
        }

        if lowered.contains(" warning:")
            || lowered.hasPrefix("warning:")
            || lowered.contains(": warning:")
        {
            return .warning
        }

        if source == .stderr, lowered.contains("exception") {
            return .error
        }

        return .info
    }

    private func scope(for message: String) -> BuildLogScope {
        if let taggedScope = taggedScope(in: message, prefix: "[device ", idPrefix: "device:") {
            return taggedScope
        }

        if let taggedScope = taggedScope(in: message, prefix: "[runtime ", idPrefix: "runtime:") {
            return taggedScope
        }

        if let taggedScope = taggedScope(in: message, prefix: "[platform ", idPrefix: "platform:") {
            return taggedScope
        }

        return .build
    }

    private func taggedScope(in message: String, prefix: String, idPrefix: String) -> BuildLogScope? {
        guard message.hasPrefix(prefix),
              let closingBracketIndex = message.firstIndex(of: "]")
        else {
            return nil
        }

        let titleStart = message.index(message.startIndex, offsetBy: prefix.count)
        guard titleStart < closingBracketIndex else {
            return nil
        }

        let title = String(message[titleStart..<closingBracketIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return nil
        }

        return BuildLogScope(id: "\(idPrefix)\(title)", title: title)
    }

    private static func loadSavedDevices() -> [DeviceDescriptor] {
        guard let data = UserDefaults.standard.data(forKey: savedDevicesKey),
              let descriptors = try? JSONDecoder().decode([DeviceDescriptor].self, from: data)
        else { return [] }
        return descriptors
    }
}

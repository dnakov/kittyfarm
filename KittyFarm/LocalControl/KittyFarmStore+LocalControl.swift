import Foundation

enum LocalControlStoreError: LocalizedError {
    case deviceNotFound(String)
    case connectionNotFound(String)
    case frameUnavailable(String)
    case screenshotUnavailable(String)
    case invalidRequest(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound(let id):
            return "Device not found: \(id)"
        case .connectionNotFound(let id):
            return "Device is not connected: \(id)"
        case .frameUnavailable(let id):
            return "No frame is available for device: \(id)"
        case .screenshotUnavailable(let id):
            return "Could not encode screenshot for device: \(id)"
        case .invalidRequest(let message):
            return message
        }
    }
}

@MainActor
extension KittyFarmStore {
    func localControlStatusResponse() -> LocalControlStatusResponse {
        LocalControlStatusResponse(
            ok: true,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            availableDeviceCount: availableDevices.count,
            activeDeviceCount: activeDevices.count,
            selectedIOSProject: selectedIOSProject,
            selectedAndroidProject: selectedAndroidProject,
            statusMessage: statusMessage
        )
    }

    func localControlDevicesResponse() -> LocalControlDevicesResponse {
        let activeByID = Dictionary(uniqueKeysWithValues: activeDevices.map { ($0.id, $0) })
        return LocalControlDevicesResponse(
            available: availableDevices.map { descriptor in
                localControlDeviceDTO(
                    descriptor: descriptor,
                    state: activeByID[descriptor.id],
                    isActive: activeByID[descriptor.id] != nil
                )
            },
            active: activeDevices.map { state in
                localControlDeviceDTO(descriptor: state.descriptor, state: state, isActive: true)
            }
        )
    }

    func localControlConnect(deviceId: String) async throws -> LocalControlOKResponse {
        if activeDevices.contains(where: { $0.id == deviceId }) {
            return LocalControlOKResponse(ok: true, message: "Device already active.")
        }
        guard let descriptor = availableDevices.first(where: { $0.id == deviceId }) else {
            throw LocalControlStoreError.deviceNotFound(deviceId)
        }
        await addDevice(descriptor)
        return LocalControlOKResponse(ok: true, message: "Connected \(descriptor.displayName).")
    }

    func localControlDisconnect(deviceId: String) async throws -> LocalControlOKResponse {
        guard let state = activeDevices.first(where: { $0.id == deviceId }) else {
            throw LocalControlStoreError.deviceNotFound(deviceId)
        }
        await removeDevice(state)
        return LocalControlOKResponse(ok: true, message: "Disconnected \(state.descriptor.displayName).")
    }

    func localControlScreenshot(deviceId: String) throws -> LocalControlScreenshotResponse {
        let state = try localControlDeviceState(deviceId)
        guard let frame = state.currentFrame, let dimensions = frame.dimensions else {
            throw LocalControlStoreError.frameUnavailable(deviceId)
        }
        guard let data = LocalControlFrameEncoder.pngData(from: frame) else {
            throw LocalControlStoreError.screenshotUnavailable(deviceId)
        }
        return LocalControlScreenshotResponse(
            deviceId: deviceId,
            width: dimensions.width,
            height: dimensions.height,
            mimeType: "image/png",
            base64: data.base64EncodedString()
        )
    }

    func localControlAccessibilityTree(deviceId: String, bundleId: String?) async throws -> [AccessibilityElement] {
        let state = try localControlDeviceState(deviceId)
        return try await localControlTreeProvider(for: state, bundleId: bundleId).fetchTree(bundleIdentifier: bundleId)
    }

    func localControlTap(_ request: LocalControlTapRequest) async throws -> LocalControlOKResponse {
        let connection = try localControlConnection(request.deviceId)
        let point: (Double, Double)
        if let query = request.query {
            let resolved = try await localControlResolve(deviceId: request.deviceId, query: query, bundleId: request.bundleId)
            point = (resolved.normalizedX, resolved.normalizedY)
        } else if let x = request.x, let y = request.y {
            point = (x, y)
        } else {
            throw LocalControlStoreError.invalidRequest("Tap requires either query or x/y.")
        }

        try await sendTap(to: connection, x: point.0, y: point.1)
        return LocalControlOKResponse(ok: true, message: "Tapped \(request.deviceId).")
    }

    func localControlSwipe(_ request: LocalControlSwipeRequest) async throws -> LocalControlOKResponse {
        let connection = try localControlConnection(request.deviceId)
        let start: (Double, Double)
        let end: (Double, Double)

        if let startX = request.startX, let startY = request.startY, let endX = request.endX, let endY = request.endY {
            start = (startX, startY)
            end = (endX, endY)
        } else {
            let center: (Double, Double)
            if let query = request.query {
                let resolved = try await localControlResolve(deviceId: request.deviceId, query: query, bundleId: request.bundleId)
                center = (resolved.normalizedX, resolved.normalizedY)
            } else {
                center = (0.5, 0.5)
            }
            (start, end) = try swipePoints(direction: request.direction, center: center)
        }

        try await sendSwipe(to: connection, from: start, to: end)
        return LocalControlOKResponse(ok: true, message: "Swiped \(request.deviceId).")
    }

    func localControlType(_ request: LocalControlTypeRequest) async throws -> LocalControlOKResponse {
        let connection = try localControlConnection(request.deviceId)
        if let query = request.query {
            let resolved = try await localControlResolve(deviceId: request.deviceId, query: query, bundleId: request.bundleId)
            try await sendTap(to: connection, x: resolved.normalizedX, y: resolved.normalizedY)
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        try await connection.setPasteboardText(request.text)
        try await Task.sleep(nanoseconds: 100_000_000)
        try await connection.sendKey(DeviceKeyboardEvent(keyCode: 9, modifiers: .command))
        return LocalControlOKResponse(ok: true, message: "Typed text on \(request.deviceId).")
    }

    func localControlPressHome(deviceId: String) async throws -> LocalControlOKResponse {
        try await localControlConnection(deviceId).pressHomeButton()
        return LocalControlOKResponse(ok: true, message: "Pressed Home.")
    }

    func localControlRotate(deviceId: String) async throws -> LocalControlOKResponse {
        try await localControlConnection(deviceId).rotateRight()
        return LocalControlOKResponse(ok: true, message: "Rotated right.")
    }

    func localControlOpenApp(_ request: LocalControlOpenAppRequest) async throws -> LocalControlOKResponse {
        try await localControlConnection(request.deviceId).openApp(request.app)
        return LocalControlOKResponse(ok: true, message: "Opened \(request.app).")
    }

    func localControlFindElement(_ request: LocalControlFindElementRequest) async throws -> LocalControlElementResponse {
        try await localControlResolve(deviceId: request.deviceId, query: request.query, bundleId: request.bundleId)
    }

    func localControlAssertVisible(_ request: LocalControlAssertRequest) async throws -> LocalControlOKResponse {
        _ = try await localControlResolve(deviceId: request.deviceId, query: request.query, bundleId: request.bundleId)
        return LocalControlOKResponse(ok: true, message: "\"\(request.query)\" is visible.")
    }

    func localControlAssertNotVisible(_ request: LocalControlAssertRequest) async throws -> LocalControlOKResponse {
        let tree = try await localControlAccessibilityTree(deviceId: request.deviceId, bundleId: request.bundleId)
        if ElementResolver.exists(request.query, in: tree) {
            throw TestRunnerError.assertionFailed("Expected \"\(request.query)\" to NOT be visible, but it was found")
        }
        return LocalControlOKResponse(ok: true, message: "\"\(request.query)\" is not visible.")
    }

    func localControlWaitFor(_ request: LocalControlWaitRequest) async throws -> LocalControlOKResponse {
        let timeout = request.timeout ?? 10
        let start = ContinuousClock.now
        while (ContinuousClock.now - start).seconds < timeout {
            let tree = try await localControlAccessibilityTree(deviceId: request.deviceId, bundleId: request.bundleId)
            if ElementResolver.exists(request.query, in: tree) {
                return LocalControlOKResponse(ok: true, message: "\"\(request.query)\" appeared.")
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw TestRunnerError.timeout(request.query, timeout)
    }

    func localControlDiscoverProject(_ request: LocalControlDiscoverProjectRequest) async throws -> LocalControlDiscoverProjectResponse {
        let url = URL(fileURLWithPath: request.path)
        let platform = request.platform?.lowercased()
        let ios = platform == nil || platform == "ios" ? try? await BuildPlayRunner.discoverIOSProject(at: url) : nil
        let android = platform == nil || platform == "android" ? try? await BuildPlayRunner.discoverAndroidProject(at: url) : nil
        if ios == nil && android == nil {
            throw LocalControlStoreError.invalidRequest("No supported iOS or Android project found at \(request.path).")
        }
        return LocalControlDiscoverProjectResponse(ios: ios, android: android)
    }

    func localControlListIOSSchemes(_ request: LocalControlIOSSchemesRequest) async throws -> LocalControlIOSSchemesResponse {
        if let path = request.path?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            let result = try await BuildPlayRunner.discoverIOSSchemes(at: URL(fileURLWithPath: path))
            let selectedScheme = selectedIOSProject?.projectURL.standardizedFileURL == result.projectURL.standardizedFileURL
                ? selectedIOSProject?.scheme
                : nil
            return LocalControlIOSSchemesResponse(
                projectPath: result.projectURL.path,
                selectedScheme: selectedScheme,
                schemes: result.schemes
            )
        }

        guard let project = selectedIOSProject else {
            throw LocalControlStoreError.invalidRequest("No selected iOS project. Pass path or select a project first.")
        }
        let schemes = project.schemes.isEmpty
            ? (try await BuildPlayRunner.discoverIOSSchemes(at: project.projectURL)).schemes
            : project.schemes
        return LocalControlIOSSchemesResponse(
            projectPath: project.projectPath,
            selectedScheme: project.scheme,
            schemes: schemes
        )
    }

    func localControlSelectIOSProject(_ request: LocalControlSelectIOSProjectRequest) async throws -> IOSProjectConfiguration {
        if let path = request.path?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            await selectIOSProject(at: URL(fileURLWithPath: path), scheme: request.scheme)
        } else if let scheme = request.scheme?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            await selectIOSScheme(scheme)
        } else {
            throw LocalControlStoreError.invalidRequest("Select iOS project requires path, scheme, or both.")
        }

        guard let selectedIOSProject else {
            throw LocalControlStoreError.invalidRequest("No iOS project selected.")
        }
        return selectedIOSProject
    }

    func localControlBuildAndRun(_ request: LocalControlBuildRunRequest) async throws -> LocalControlOKResponse {
        if let path = request.iosProjectPath {
            let url = URL(fileURLWithPath: path)
            let savedScheme = selectedIOSProject?.projectURL.standardizedFileURL == url.standardizedFileURL
                ? selectedIOSProject?.scheme
                : nil
            selectedIOSProject = try await BuildPlayRunner.discoverIOSProject(
                at: url,
                scheme: request.iosScheme ?? savedScheme
            )
            persistSelectedProjects()
        } else if let scheme = request.iosScheme?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            await selectIOSScheme(scheme)
        }
        if let path = request.androidProjectPath {
            selectedAndroidProject = try await BuildPlayRunner.discoverAndroidProject(at: URL(fileURLWithPath: path))
            persistSelectedProjects()
        }

        if let ids = request.deviceIds, !ids.isEmpty {
            let selected = Set(ids)
            let missing = selected.subtracting(Set(activeDevices.map(\.id)))
            if !missing.isEmpty {
                throw LocalControlStoreError.invalidRequest("Build requested inactive devices: \(missing.sorted().joined(separator: ", "))")
            }
            for device in activeDevices where selected.contains(device.id) {
                await buildAndPlay(for: device)
            }
        } else {
            await buildAndPlay()
        }

        return LocalControlOKResponse(ok: true, message: statusMessage)
    }

    func localControlLogs(limit: Int) -> LocalControlLogsResponse {
        let slice = buildLogs.suffix(max(1, min(limit, 1000)))
        return LocalControlLogsResponse(logs: slice.map { entry in
            LocalControlLogDTO(
                id: entry.id.uuidString,
                timestamp: entry.timestamp,
                source: entry.source.rawValue,
                severity: entry.severity.rawValue,
                scope: entry.scope.id,
                message: entry.message
            )
        })
    }

    func localControlReadLogs(_ request: LocalControlReadLogsRequest) throws -> LocalControlReadLogsResponse {
        let limit = max(1, min(request.limit ?? 50, 200))
        let maxMessageLength = max(120, min(request.maxMessageLength ?? 600, 2_000))
        let minimumSeverity = try parseSeverity(request.minimumSeverity ?? "info")
        let source = try parseSource(request.source)
        let normalizedSearch = request.search?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let normalizedScope = request.scope?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let newestFirst = request.newestFirst ?? false

        let matched = buildLogs.filter { entry in
            guard entry.severity.rank >= minimumSeverity.rank else { return false }
            if let source, entry.source != source { return false }
            if let normalizedScope, entry.scope.id != normalizedScope { return false }
            if let since = request.since, entry.timestamp < since { return false }
            if let normalizedSearch,
               entry.message.range(of: normalizedSearch, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                return false
            }
            return true
        }

        var selected = Array(matched.suffix(limit))
        if newestFirst {
            selected.reverse()
        }

        var truncatedCount = 0
        let logs = selected.map { entry in
            let message = truncate(entry.message, maxLength: maxMessageLength)
            if message != entry.message {
                truncatedCount += 1
            }
            return localControlLogDTO(entry, message: message)
        }

        return LocalControlReadLogsResponse(
            totalAvailable: buildLogs.count,
            matchedCount: matched.count,
            returnedCount: logs.count,
            omittedCount: max(matched.count - logs.count, 0),
            truncatedMessageCount: truncatedCount,
            limit: limit,
            maxMessageLength: maxMessageLength,
            filters: LocalControlLogFilters(
                minimumSeverity: minimumSeverity.rawValue,
                source: source?.rawValue,
                scope: normalizedScope,
                search: normalizedSearch,
                since: request.since,
                newestFirst: newestFirst
            ),
            logs: logs
        )
    }

    func localControlCrashReports(_ request: LocalControlCrashReportsRequest) throws -> LocalControlCrashReportsResponse {
        try LocalControlCrashReportReader.read(request)
    }

    func localControlStartScreenRecording(_ request: LocalControlScreenRecordingRequest) throws -> LocalControlScreenRecordingResponse {
        let targets = try localControlRecordingTargets(request)
        let fps = max(1, min(request.fps ?? 10, 30))
        let maxDurationSeconds = request.maxDurationSeconds.map { max(1, min($0, 600)) }
        let recordings = try targets.map { state in
            let result = try startScreenRecording(on: state, fps: fps, maxDurationSeconds: maxDurationSeconds)
            return localControlScreenRecordingDTO(
                result,
                isActive: true
            )
        }
        return LocalControlScreenRecordingResponse(recordings: recordings)
    }

    func localControlStopScreenRecording(_ request: LocalControlScreenRecordingRequest) async throws -> LocalControlScreenRecordingResponse {
        let targets = try localControlRecordingTargets(request).filter(\.isScreenRecording)
        var recordings: [LocalControlScreenRecordingDTO] = []
        for state in targets {
            let result = try await stopScreenRecording(on: state)
            recordings.append(localControlScreenRecordingDTO(result, isActive: false))
        }
        return LocalControlScreenRecordingResponse(
            recordings: recordings.sorted { $0.deviceName.localizedStandardCompare($1.deviceName) == .orderedAscending }
        )
    }

    func localControlScreenRecordingStatus() -> LocalControlScreenRecordingResponse {
        let recordings = activeDevices.compactMap { state -> LocalControlScreenRecordingDTO? in
            guard state.isScreenRecording, let recorder = screenRecorder(for: state.id) else { return nil }
            return localControlScreenRecordingDTO(activeRecordingResult(recorder), isActive: true)
        }
        return LocalControlScreenRecordingResponse(recordings: recordings)
    }

    private func localControlDeviceDTO(
        descriptor: DeviceDescriptor,
        state: DeviceState?,
        isActive: Bool
    ) -> LocalControlDeviceDTO {
        let dimensions = state?.currentFrame?.dimensions
        return LocalControlDeviceDTO(
            id: descriptor.id,
            platform: descriptor.platform.rawValue,
            displayName: descriptor.displayName,
            subtitle: descriptor.subtitle,
            isActive: isActive,
            isConnected: state?.isConnected ?? false,
            isConnecting: state?.isConnecting ?? false,
            frameWidth: dimensions?.width,
            frameHeight: dimensions?.height,
            fps: state?.fps ?? 0,
            latencyMs: state?.latencyMs ?? 0,
            lastError: state?.lastError,
            isScreenRecording: state?.isScreenRecording ?? false,
            screenRecordingOutputPath: state?.screenRecordingOutputPath
        )
    }

    private func localControlScreenRecordingDTO(_ result: ScreenRecordingResult, isActive: Bool) -> LocalControlScreenRecordingDTO {
        LocalControlScreenRecordingDTO(
            recordingId: result.recordingId,
            deviceId: result.deviceId,
            deviceName: result.deviceName,
            path: result.outputURL.path,
            fileName: result.outputURL.lastPathComponent,
            startedAt: result.startedAt,
            finishedAt: isActive ? nil : result.finishedAt,
            durationSeconds: result.durationSeconds,
            frameCount: result.frameCount,
            width: result.width,
            height: result.height,
            fps: result.fps,
            isActive: isActive
        )
    }

    private func localControlRecordingTargets(_ request: LocalControlScreenRecordingRequest) throws -> [DeviceState] {
        if request.allActive == true {
            return activeDevices
        }

        var ids: [String] = []
        if let deviceId = request.deviceId {
            ids.append(deviceId)
        }
        if let deviceIds = request.deviceIds {
            ids.append(contentsOf: deviceIds)
        }

        guard !ids.isEmpty else {
            throw LocalControlStoreError.invalidRequest("Screen recording requires deviceId, deviceIds, or allActive=true.")
        }

        let statesByID = Dictionary(uniqueKeysWithValues: activeDevices.map { ($0.id, $0) })
        return try ids.uniqued().map { id in
            guard let state = statesByID[id] else {
                throw LocalControlStoreError.deviceNotFound(id)
            }
            return state
        }
    }

    private func localControlLogDTO(_ entry: BuildLogEntry, message: String? = nil) -> LocalControlLogDTO {
        LocalControlLogDTO(
            id: entry.id.uuidString,
            timestamp: entry.timestamp,
            source: entry.source.rawValue,
            severity: entry.severity.rawValue,
            scope: entry.scope.id,
            message: message ?? entry.message
        )
    }

    private func parseSeverity(_ value: String) throws -> BuildLogSeverity {
        switch value.lowercased() {
        case "info": return .info
        case "warning", "warn": return .warning
        case "error": return .error
        default:
            throw LocalControlStoreError.invalidRequest("minimumSeverity must be one of: info, warning, error.")
        }
    }

    private func parseSource(_ value: String?) throws -> BuildLogSource? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }
        guard let source = BuildLogSource(rawValue: value.lowercased()) else {
            throw LocalControlStoreError.invalidRequest("source must be one of: command, stdout, stderr, system.")
        }
        return source
    }

    private func truncate(_ message: String, maxLength: Int) -> String {
        guard message.count > maxLength else { return message }
        let end = message.index(message.startIndex, offsetBy: maxLength)
        return String(message[..<end]) + "... [truncated \(message.count - maxLength) chars]"
    }

    private func localControlDeviceState(_ deviceId: String) throws -> DeviceState {
        guard let state = activeDevices.first(where: { $0.id == deviceId }) else {
            throw LocalControlStoreError.deviceNotFound(deviceId)
        }
        return state
    }

    private func localControlConnection(_ deviceId: String) throws -> AnyDeviceConnectionBox {
        guard let connection = connections[deviceId] else {
            throw LocalControlStoreError.connectionNotFound(deviceId)
        }
        return connection
    }

    private func localControlTreeProvider(for state: DeviceState, bundleId: String?) -> any AccessibilityTreeProvider {
        let size = state.currentFrame?.dimensions
        switch state.descriptor {
        case let .iOSSimulator(udid, _, _):
            return IOSAccessibilityProvider(
                udid: udid,
                screenWidth: Double(size?.width ?? 390),
                screenHeight: Double(size?.height ?? 844),
                bundleIdentifier: bundleId
            )
        case let .androidEmulator(avdName, _):
            return LazyAndroidAccessibilityProvider(
                avdName: avdName,
                screenWidth: Double(size?.width ?? 1080),
                screenHeight: Double(size?.height ?? 2400)
            )
        }
    }

    private func localControlResolve(deviceId: String, query: String, bundleId: String?) async throws -> LocalControlElementResponse {
        let state = try localControlDeviceState(deviceId)
        let provider = localControlTreeProvider(for: state, bundleId: bundleId)
        let tree = try await provider.fetchTree(bundleIdentifier: bundleId)
        let size = try await provider.screenSize()
        let resolved = try ElementResolver.resolve(query, in: tree, screenWidth: size.width, screenHeight: size.height)
        return LocalControlElementResponse(
            element: resolved.element,
            normalizedX: resolved.normalizedX,
            normalizedY: resolved.normalizedY
        )
    }

    private func sendTap(to connection: AnyDeviceConnectionBox, x: Double, y: Double) async throws {
        try await connection.sendTouch(NormalizedTouch(nx: x, ny: y, phase: .began, pressure: 1, id: 0))
        try await Task.sleep(nanoseconds: 50_000_000)
        try await connection.sendTouch(NormalizedTouch(nx: x, ny: y, phase: .ended, pressure: 0, id: 0))
    }

    private func sendSwipe(
        to connection: AnyDeviceConnectionBox,
        from start: (Double, Double),
        to end: (Double, Double)
    ) async throws {
        try await connection.sendTouch(NormalizedTouch(nx: start.0, ny: start.1, phase: .began, pressure: 1, id: 0))
        for i in 1...10 {
            let t = Double(i) / 10
            try await connection.sendTouch(NormalizedTouch(
                nx: start.0 + (end.0 - start.0) * t,
                ny: start.1 + (end.1 - start.1) * t,
                phase: .moved,
                pressure: 1,
                id: 0
            ))
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        try await connection.sendTouch(NormalizedTouch(nx: end.0, ny: end.1, phase: .ended, pressure: 0, id: 0))
    }

    private func swipePoints(direction: String?, center: (Double, Double)) throws -> ((Double, Double), (Double, Double)) {
        let offset = 0.2
        switch direction?.lowercased() {
        case "up":
            return ((center.0, center.1 + offset), (center.0, center.1 - offset))
        case "down":
            return ((center.0, center.1 - offset), (center.0, center.1 + offset))
        case "left":
            return ((center.0 + offset, center.1), (center.0 - offset, center.1))
        case "right":
            return ((center.0 - offset, center.1), (center.0 + offset, center.1))
        default:
            throw LocalControlStoreError.invalidRequest("Swipe requires direction or explicit start/end coordinates.")
        }
    }
}

private extension BuildLogSeverity {
    var rawValue: String {
        switch self {
        case .info: return "info"
        case .warning: return "warning"
        case .error: return "error"
        }
    }

    var rank: Int {
        switch self {
        case .info: return 0
        case .warning: return 1
        case .error: return 2
        }
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let (s, atto) = components
        return Double(s) + Double(atto) * 1e-18
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

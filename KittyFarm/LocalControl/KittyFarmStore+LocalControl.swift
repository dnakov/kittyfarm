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

    func localControlBuildAndRun(_ request: LocalControlBuildRunRequest) async throws -> LocalControlOKResponse {
        if let path = request.iosProjectPath {
            selectedIOSProject = try await BuildPlayRunner.discoverIOSProject(at: URL(fileURLWithPath: path))
        }
        if let path = request.androidProjectPath {
            selectedAndroidProject = try await BuildPlayRunner.discoverAndroidProject(at: URL(fileURLWithPath: path))
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
            lastError: state?.lastError
        )
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
}

private extension Duration {
    var seconds: TimeInterval {
        let (s, atto) = components
        return Double(s) + Double(atto) * 1e-18
    }
}

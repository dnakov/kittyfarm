import Foundation

enum TestRunnerError: LocalizedError {
    case noConnection(String)
    case timeout(String, TimeInterval)
    case assertionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noConnection(let device):
            return "No connection to device: \(device)"
        case .timeout(let element, let seconds):
            return "Timed out waiting for \"\(element)\" after \(Int(seconds))s"
        case .assertionFailed(let message):
            return message
        }
    }
}

actor TestRunner {
    typealias Logger = @Sendable (TestStepResult) async -> Void

    private let defaultWaitTimeout: TimeInterval = 10
    private let tapDuration: UInt64 = 50_000_000
    private let swipeSteps = 10
    private let swipeDuration: UInt64 = 300_000_000

    func run(
        script: [TestAction],
        connection: AnyDeviceConnectionBox,
        treeProvider: AccessibilityTreeProvider,
        logger: Logger? = nil
    ) async -> TestRunResult {
        var steps: [TestStepResult] = []

        for action in script {
            let start = ContinuousClock.now
            let result: TestStepResult

            do {
                try await execute(action: action, connection: connection, treeProvider: treeProvider)
                let elapsed = ContinuousClock.now - start
                result = TestStepResult(
                    action: action,
                    status: .passed,
                    duration: elapsed.seconds,
                    message: nil
                )
            } catch {
                let elapsed = ContinuousClock.now - start
                result = TestStepResult(
                    action: action,
                    status: .failed,
                    duration: elapsed.seconds,
                    message: error.localizedDescription
                )
            }

            steps.append(result)
            await logger?(result)

            if result.status == .failed {
                break
            }
        }

        return TestRunResult(steps: steps)
    }

    private func execute(
        action: TestAction,
        connection: AnyDeviceConnectionBox,
        treeProvider: AccessibilityTreeProvider
    ) async throws {
        switch action {
        case .tap(let element):
            let resolved = try await resolveElement(element, treeProvider: treeProvider)
            try await performTap(at: resolved, connection: connection)

        case .doubleTap(let element):
            let resolved = try await resolveElement(element, treeProvider: treeProvider)
            try await performTap(at: resolved, connection: connection)
            try await Task.sleep(nanoseconds: 100_000_000)
            try await performTap(at: resolved, connection: connection)

        case .longPress(let element):
            let resolved = try await resolveElement(element, treeProvider: treeProvider)
            let touch = NormalizedTouch(
                nx: resolved.normalizedX,
                ny: resolved.normalizedY,
                phase: .began,
                pressure: 1,
                id: 0
            )
            try await connection.sendTouch(touch)
            try await Task.sleep(nanoseconds: 500_000_000)
            let endTouch = NormalizedTouch(
                nx: resolved.normalizedX,
                ny: resolved.normalizedY,
                phase: .ended,
                pressure: 0,
                id: 0
            )
            try await connection.sendTouch(endTouch)

        case .type(let text, let element):
            if let element {
                let resolved = try await resolveElement(element, treeProvider: treeProvider)
                try await performTap(at: resolved, connection: connection)
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            try await connection.setPasteboardText(text)
            try await Task.sleep(nanoseconds: 100_000_000)
            let cmdV = DeviceKeyboardEvent(keyCode: 9, modifiers: .command)
            try await connection.sendKey(cmdV)

        case .swipe(let direction, let element):
            let (startX, startY, endX, endY): (Double, Double, Double, Double)

            if let element {
                let resolved = try await resolveElement(element, treeProvider: treeProvider)
                let cx = resolved.normalizedX
                let cy = resolved.normalizedY
                let offset = 0.2
                switch direction {
                case .up:    (startX, startY, endX, endY) = (cx, cy + offset, cx, cy - offset)
                case .down:  (startX, startY, endX, endY) = (cx, cy - offset, cx, cy + offset)
                case .left:  (startX, startY, endX, endY) = (cx + offset, cy, cx - offset, cy)
                case .right: (startX, startY, endX, endY) = (cx - offset, cy, cx + offset, cy)
                }
            } else {
                switch direction {
                case .up:    (startX, startY, endX, endY) = (0.5, 0.7, 0.5, 0.3)
                case .down:  (startX, startY, endX, endY) = (0.5, 0.3, 0.5, 0.7)
                case .left:  (startX, startY, endX, endY) = (0.7, 0.5, 0.3, 0.5)
                case .right: (startX, startY, endX, endY) = (0.3, 0.5, 0.7, 0.5)
                }
            }

            try await performSwipe(
                from: (startX, startY),
                to: (endX, endY),
                connection: connection
            )

        case .waitFor(let element, let timeout):
            let deadline = timeout ?? defaultWaitTimeout
            let start = ContinuousClock.now
            while (ContinuousClock.now - start).seconds < deadline {
                let tree = try await treeProvider.fetchTree(bundleIdentifier: nil)
                if ElementResolver.exists(element, in: tree) {
                    return
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            throw TestRunnerError.timeout(element, deadline)

        case .assertVisible(let element):
            let tree = try await treeProvider.fetchTree(bundleIdentifier: nil)
            let size = try await treeProvider.screenSize()
            _ = try ElementResolver.resolve(element, in: tree, screenWidth: size.width, screenHeight: size.height)

        case .assertNotVisible(let element):
            let tree = try await treeProvider.fetchTree(bundleIdentifier: nil)
            if ElementResolver.exists(element, in: tree) {
                throw TestRunnerError.assertionFailed("Expected \"\(element)\" to NOT be visible, but it was found")
            }

        case .pressHome:
            try await connection.pressHomeButton()

        case .pause(let duration):
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))

        case .open(let app):
            try await connection.openApp(app)
            // Apps take a moment to appear — brief grace period before the next action.
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    private func resolveElement(
        _ query: String,
        treeProvider: AccessibilityTreeProvider
    ) async throws -> ResolvedElement {
        let tree = try await treeProvider.fetchTree(bundleIdentifier: nil)
        let size = try await treeProvider.screenSize()
        return try ElementResolver.resolve(query, in: tree, screenWidth: size.width, screenHeight: size.height)
    }

    private func performTap(at resolved: ResolvedElement, connection: AnyDeviceConnectionBox) async throws {
        let began = NormalizedTouch(
            nx: resolved.normalizedX,
            ny: resolved.normalizedY,
            phase: .began,
            pressure: 1,
            id: 0
        )
        try await connection.sendTouch(began)
        try await Task.sleep(nanoseconds: tapDuration)
        let ended = NormalizedTouch(
            nx: resolved.normalizedX,
            ny: resolved.normalizedY,
            phase: .ended,
            pressure: 0,
            id: 0
        )
        try await connection.sendTouch(ended)
    }

    private func performSwipe(
        from start: (x: Double, y: Double),
        to end: (x: Double, y: Double),
        connection: AnyDeviceConnectionBox
    ) async throws {
        let began = NormalizedTouch(nx: start.x, ny: start.y, phase: .began, pressure: 1, id: 0)
        try await connection.sendTouch(began)

        let stepDelay = swipeDuration / UInt64(swipeSteps)
        for i in 1...swipeSteps {
            let t = Double(i) / Double(swipeSteps)
            let x = start.x + (end.x - start.x) * t
            let y = start.y + (end.y - start.y) * t
            let moved = NormalizedTouch(nx: x, ny: y, phase: .moved, pressure: 1, id: 0)
            try await connection.sendTouch(moved)
            try await Task.sleep(nanoseconds: stepDelay)
        }

        let ended = NormalizedTouch(nx: end.x, ny: end.y, phase: .ended, pressure: 0, id: 0)
        try await connection.sendTouch(ended)
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let (s, atto) = components
        return Double(s) + Double(atto) * 1e-18
    }
}

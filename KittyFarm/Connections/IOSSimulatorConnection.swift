import AppKit
import Foundation

@MainActor
final class IOSSimulatorConnection: NSObject, DeviceConnection, @preconcurrency PrivateSimulatorDisplayBridgeDelegate {
    nonisolated let descriptor: DeviceDescriptor

    private static let selfTestEnabled = ProcessInfo.processInfo.environment["KITTYFARM_PRIVATE_SIM_SELF_TEST"] == "1"

    private let state: DeviceState
    private let displayBridge: PrivateSimulatorDisplayBridge
    private let simctlManager = SimctlManager()
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var didRunSelfTestTap = false

    init(descriptor: DeviceDescriptor, state: DeviceState) throws {
        self.descriptor = descriptor
        self.state = state

        guard case let .iOSSimulator(udid, _, _) = descriptor else {
            throw IOSSimulatorConnectionError.unsupportedDescriptor
        }

        displayBridge = try PrivateSimulatorDisplayBridge(udid: udid)
        super.init()
        displayBridge.delegate = self
        state.simulatorDisplayBridge = displayBridge
        state.privateDisplayReady = displayBridge.isDisplayReady
        state.privateDisplayStatus = displayBridge.displayStatus
        syncLatestFrameFromBridge()
        runSelfTestTapIfNeeded()
    }

    func connect() async throws {
        state.privateDisplayReady = displayBridge.isDisplayReady
        state.privateDisplayStatus = displayBridge.displayStatus

        if displayBridge.isDisplayReady {
            syncLatestFrameFromBridge()
            runSelfTestTapIfNeeded()
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            connectContinuation = continuation
            connectTimeoutTask?.cancel()
            connectTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                await MainActor.run {
                    self?.failPendingConnect()
                }
            }
        }
    }

    func disconnect() async {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        completePendingConnect(with: .failure(CancellationError()))
        displayBridge.disconnect()
        displayBridge.delegate = nil
        state.simulatorDisplayBridge = nil
        state.privateDisplayReady = false
        state.privateDisplayStatus = nil
        state.noteDisconnected()
    }

    func sendTouch(_ touch: NormalizedTouch) async throws {
        try displayBridge.sendTouch(
            normalizedX: touch.clampedX,
            normalizedY: touch.clampedY,
            phase: touch.privateSimulatorPhase
        )
    }

    func sendKey(_ keyEvent: DeviceKeyboardEvent) async throws {
        try displayBridge.sendKey(
            keyCode: keyEvent.keyCode,
            modifiers: UInt(keyEvent.modifiers.rawValue)
        )
    }

    func sendHardwareKeyboardEvent(_ event: NSEvent) async throws {
        try displayBridge.sendKey(event: event)
    }

    func setPasteboardText(_ text: String) async throws {
        try await simctlManager.setPasteboard(text, for: descriptor)
    }

    func pressHomeButton() async throws {
        try displayBridge.pressHomeButton()
    }

    func rotateRight() async throws {
        try displayBridge.rotateRight()
    }

    func privateSimulatorDisplayBridge(_ bridge: PrivateSimulatorDisplayBridge, didUpdateFrame pixelBuffer: CVPixelBuffer) {
        guard let ownedPixelBuffer = bridge.copyPixelBuffer() else {
            state.privateDisplayReady = false
            return
        }

        state.noteFrame(.pixelBuffer(ownedPixelBuffer))
        state.privateDisplayReady = true
        completePendingConnect(with: .success(()))
    }

    func privateSimulatorDisplayBridge(_ bridge: PrivateSimulatorDisplayBridge, didChangeDisplayStatus status: String, isReady: Bool) {
        state.privateDisplayReady = isReady
        state.privateDisplayStatus = status

        if isReady {
            syncLatestFrameFromBridge()
            completePendingConnect(with: .success(()))
            runSelfTestTapIfNeeded()
        }
    }

    private func failPendingConnect() {
        completePendingConnect(with: .failure(IOSSimulatorConnectionError.privateDisplayUnavailable(displayBridge.displayStatus)))
    }

    private func completePendingConnect(with result: Result<Void, Error>) {
        guard let continuation = connectContinuation else {
            return
        }

        connectContinuation = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil

        switch result {
        case .success:
            continuation.resume()
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }

    private func syncLatestFrameFromBridge() {
        guard let ownedPixelBuffer = displayBridge.copyPixelBuffer() else {
            return
        }

        state.noteFrame(.pixelBuffer(ownedPixelBuffer))
        state.privateDisplayReady = true
    }

    private func runSelfTestTapIfNeeded() {
        guard Self.selfTestEnabled, !didRunSelfTestTap else {
            return
        }

        didRunSelfTestTap = true
        Task {
            do {
                print("[KittyFarm][IOSSim] Running private HID self-test tap for \(descriptor.displayName)")
                try displayBridge.sendTouch(normalizedX: 0.5, normalizedY: 0.5, phase: .began)
                try await Task.sleep(for: .milliseconds(75))
                try displayBridge.sendTouch(normalizedX: 0.5, normalizedY: 0.5, phase: .ended)
                print("[KittyFarm][IOSSim] Private HID self-test tap completed for \(descriptor.displayName)")
            } catch {
                print("[KittyFarm][IOSSim] Private HID self-test tap failed for \(descriptor.displayName): \(error.localizedDescription)")
            }
        }
    }
}

private extension NormalizedTouch {
    var privateSimulatorPhase: PrivateSimulatorTouchPhase {
        switch phase {
        case .began:
            .began
        case .moved:
            .moved
        case .ended:
            .ended
        case .cancelled:
            .cancelled
        }
    }
}

enum IOSSimulatorConnectionError: LocalizedError {
    case unsupportedDescriptor
    case privateDisplayUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedDescriptor:
            return "The private iOS simulator connection was created for a non-iOS device descriptor."
        case let .privateDisplayUnavailable(status):
            return "Private SimulatorKit attach failed: \(status)"
        }
    }
}

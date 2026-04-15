import AppKit
import Foundation

final class AndroidEmulatorConnection: DeviceConnection {
    let descriptor: DeviceDescriptor

    private let state: DeviceState
    private let frameService: GRPCFrameService
    private let touchInjector: GRPCTouchInjector

    init(descriptor: DeviceDescriptor, state: DeviceState) {
        self.descriptor = descriptor
        self.state = state
        frameService = GRPCFrameService(descriptor: descriptor)
        touchInjector = GRPCTouchInjector(descriptor: descriptor, state: state)
    }

    func connect() async throws {
        try await frameService.startStreaming(into: state)
    }

    func disconnect() async {
        await frameService.stop()
        let state = self.state
        await MainActor.run {
            state.noteDisconnected()
        }
    }

    func sendTouch(_ touch: NormalizedTouch) async throws {
        try await touchInjector.sendTouch(touch)
    }

    func sendKey(_ keyEvent: DeviceKeyboardEvent) async throws {
        try await touchInjector.sendKey(keyEvent)
    }

    func sendHardwareKeyboardEvent(_ event: NSEvent) async throws {
        guard event.type == .keyDown else {
            return
        }

        try await touchInjector.sendKey(DeviceKeyboardEvent(event: event))
    }

    func setPasteboardText(_ text: String) async throws {
        try await touchInjector.setPasteboardText(text)
    }

    func pressHomeButton() async throws {}

    func rotateRight() async throws {}
}

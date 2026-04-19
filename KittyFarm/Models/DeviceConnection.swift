import AppKit
import Foundation

protocol DeviceConnection: AnyObject {
    var descriptor: DeviceDescriptor { get }
    func connect() async throws
    func disconnect() async
    func sendTouch(_ touch: NormalizedTouch) async throws
    func sendKey(_ keyEvent: DeviceKeyboardEvent) async throws
    @MainActor func sendHardwareKeyboardEvent(_ event: NSEvent) async throws
    func setPasteboardText(_ text: String) async throws
    func triggerSimulatorControl(_ identifier: String) async throws
    func pressHomeButton() async throws
    func rotateRight() async throws
    func openApp(_ nameOrBundleID: String) async throws
}

final class AnyDeviceConnectionBox: @unchecked Sendable {
    private let base: any DeviceConnection

    init(_ base: any DeviceConnection) {
        self.base = base
    }

    var descriptor: DeviceDescriptor {
        base.descriptor
    }

    func connect() async throws {
        try await base.connect()
    }

    func disconnect() async {
        await base.disconnect()
    }

    func sendTouch(_ touch: NormalizedTouch) async throws {
        try await base.sendTouch(touch)
    }

    func sendKey(_ keyEvent: DeviceKeyboardEvent) async throws {
        try await base.sendKey(keyEvent)
    }

    @MainActor
    func sendHardwareKeyboardEvent(_ event: NSEvent) async throws {
        try await base.sendHardwareKeyboardEvent(event)
    }

    func setPasteboardText(_ text: String) async throws {
        try await base.setPasteboardText(text)
    }

    func triggerSimulatorControl(_ identifier: String) async throws {
        try await base.triggerSimulatorControl(identifier)
    }

    func pressHomeButton() async throws {
        try await base.pressHomeButton()
    }

    func rotateRight() async throws {
        try await base.rotateRight()
    }

    func openApp(_ nameOrBundleID: String) async throws {
        try await base.openApp(nameOrBundleID)
    }
}

import CoreVideo
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

struct GRPCTouchInjector {
    private static let emulatorGRPCAddress = "127.0.0.1"

    let descriptor: DeviceDescriptor
    let state: DeviceState

    func sendTouch(_ touch: NormalizedTouch) async throws {
        let size = try await currentFrameSize()
        let event = makeTouchEvent(from: touch, size: size)

        try await withEmulatorClient { emulator in
            try await emulator.sendTouch(event)
        }
    }

    func sendKey(_ keyEvent: DeviceKeyboardEvent) async throws {
        try await withEmulatorClient { emulator in
            for modifierKeyCode in keyEvent.modifiers.orderedKeyCodes {
                var event = Android_Emulation_Control_KeyboardEvent()
                event.codeType = .mac
                event.eventType = .keydown
                event.keyCode = Int32(modifierKeyCode)
                try await emulator.sendKey(event)
            }

            var keyDown = Android_Emulation_Control_KeyboardEvent()
            keyDown.codeType = .mac
            keyDown.eventType = .keydown
            keyDown.keyCode = Int32(keyEvent.keyCode)
            try await emulator.sendKey(keyDown)

            var keyUp = Android_Emulation_Control_KeyboardEvent()
            keyUp.codeType = .mac
            keyUp.eventType = .keyup
            keyUp.keyCode = Int32(keyEvent.keyCode)
            try await emulator.sendKey(keyUp)

            for modifierKeyCode in keyEvent.modifiers.orderedKeyCodes.reversed() {
                var event = Android_Emulation_Control_KeyboardEvent()
                event.codeType = .mac
                event.eventType = .keyup
                event.keyCode = Int32(modifierKeyCode)
                try await emulator.sendKey(event)
            }
        }
    }

    func setPasteboardText(_ text: String) async throws {
        try await withEmulatorClient { emulator in
            var clipData = Android_Emulation_Control_ClipData()
            clipData.text = text
            try await emulator.setClipboard(clipData)
        }
    }

    private func currentFrameSize() async throws -> CGSize {
        let dimensions: CGSize? = await MainActor.run {
            switch state.currentFrame {
            case let .pixelBuffer(pixelBuffer):
                return CGSize(
                    width: CVPixelBufferGetWidth(pixelBuffer),
                    height: CVPixelBufferGetHeight(pixelBuffer)
                )
            case let .bitmap(frame):
                return CGSize(width: frame.width, height: frame.height)
            case .none:
                return nil
            }
        }

        guard let dimensions, dimensions.width > 0, dimensions.height > 0 else {
            throw AndroidGRPCError.missingFrameDimensions
        }

        return dimensions
    }

    private func makeTouchEvent(from touch: NormalizedTouch, size: CGSize) -> Android_Emulation_Control_TouchEvent {
        let maxX = max(size.width - 1, 0)
        let maxY = max(size.height - 1, 0)

        var point = Android_Emulation_Control_Touch()
        point.x = Int32((touch.clampedX * maxX).rounded())
        point.y = Int32((touch.clampedY * maxY).rounded())
        point.identifier = Int32(touch.id)
        point.pressure = touch.phase == .ended || touch.phase == .cancelled ? 0 : max(Int32(touch.pressure.rounded()), 1)
        point.touchMajor = 1
        point.touchMinor = 1
        point.expiration = .neverExpire
        point.orientation = 0

        var event = Android_Emulation_Control_TouchEvent()
        event.touches = [point]
        return event
    }

    private func withEmulatorClient<Result: Sendable>(
        _ body: @Sendable (any Android_Emulation_Control_EmulatorController.ClientProtocol) async throws -> Result
    ) async throws -> Result {
        guard let grpcPort = descriptor.androidGRPCPort else {
            throw AndroidGRPCError.invalidDescriptor
        }

        return try await withGRPCClient(
            transport: .http2NIOPosix(
                target: .ipv4(address: Self.emulatorGRPCAddress, port: grpcPort),
                transportSecurity: .plaintext
            )
        ) { client in
            let emulator = Android_Emulation_Control_EmulatorController.Client(wrapping: client)
            return try await body(emulator)
        }
    }
}

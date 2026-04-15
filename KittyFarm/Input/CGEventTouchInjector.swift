import CoreGraphics
import Foundation

struct CGEventTouchInjector {
    let descriptor: DeviceDescriptor
    let matcher: SimulatorWindowMatcher

    func sendTouch(_ touch: NormalizedTouch) async throws {
        let match = try await matcher.matchWindow(for: descriptor)
        let point = CGPoint(
            x: match.bounds.minX + match.bounds.width * touch.clampedX,
            y: match.bounds.minY + match.bounds.height * touch.clampedY
        )

        let eventType: CGEventType
        switch touch.phase {
        case .began:
            eventType = .leftMouseDown
        case .moved:
            eventType = .leftMouseDragged
        case .ended, .cancelled:
            eventType = .leftMouseUp
        }

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: eventType,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            throw CGEventTouchInjectorError.eventCreationFailed
        }

        event.postToPid(match.pid)
    }
}

enum CGEventTouchInjectorError: LocalizedError {
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .eventCreationFailed:
            return "Unable to create a Quartz mouse event for simulator touch injection."
        }
    }
}

import Foundation

struct NormalizedTouch: Sendable {
    enum Phase: String, Sendable {
        case began
        case moved
        case ended
        case cancelled
    }

    let nx: Double
    let ny: Double
    let phase: Phase
    let pressure: Double
    let id: Int

    var clampedX: Double {
        min(max(nx, 0), 1)
    }

    var clampedY: Double {
        min(max(ny, 0), 1)
    }
}

import Foundation

struct MemorySample: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let footprintMB: Double
    let residentMB: Double
    let dirtyMB: Double
}

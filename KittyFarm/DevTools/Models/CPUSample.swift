import Foundation

struct CPUSample: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let cpuPercent: Double
    let threadCount: Int?
}

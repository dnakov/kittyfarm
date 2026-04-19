import Foundation

struct SampleTreeNode: Identifiable, Hashable, Sendable {
    let id = UUID()
    let symbol: String
    let module: String?
    let sampleCount: Int
    let selfSampleCount: Int
    let children: [SampleTreeNode]

    static func == (lhs: SampleTreeNode, rhs: SampleTreeNode) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

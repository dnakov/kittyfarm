import Foundation

protocol AccessibilityTreeProvider: Sendable {
    func fetchTree(bundleIdentifier: String?) async throws -> [AccessibilityElement]
    func screenSize() async throws -> (width: Double, height: Double)
}

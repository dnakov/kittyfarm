import Foundation
import GRPCCore
import Metal
import Observation
import QuartzCore

struct SimulatorChromeControl: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let toolTip: String
    let accessibilityLabel: String
    let summary: String

    init(button: PrivateSimulatorChromeButton) {
        id = button.identifier
        title = button.title
        toolTip = button.toolTip
        accessibilityLabel = button.accessibilityLabel
        summary = button.summary
    }

    var displayName: String {
        if !title.isEmpty { return title }
        if !accessibilityLabel.isEmpty { return accessibilityLabel }
        if !toolTip.isEmpty { return toolTip }
        return summary
    }

    var helpText: String {
        let name = displayName
        if summary.isEmpty || summary == name {
            return name
        }
        return "\(name) • \(summary)"
    }

    var systemImage: String {
        let text = "\(displayName) \(summary)".lowercased()

        if text.contains("home") { return "house.fill" }
        if text.contains("lock") { return "lock.fill" }
        if text.contains("side") || text.contains("power") { return "power" }
        if text.contains("siri") { return "waveform" }
        if text.contains("screenshot") || text.contains("capture") { return "camera.fill" }
        if text.contains("keyboard") { return "keyboard.fill" }
        if text.contains("pointer") || text.contains("mouse") || text.contains("trackpad") { return "cursorarrow" }
        if text.contains("shake") { return "iphone.radiowaves.left.and.right" }
        if text.contains("menu") { return "line.3.horizontal.circle.fill" }
        if text.contains("tv") { return "tv.fill" }
        if text.contains("play") || text.contains("pause") { return "playpause.fill" }
        if text.contains("watch") { return "applewatch" }
        return "switch.2"
    }

    var isHomeLike: Bool {
        "\(displayName) \(summary)".lowercased().contains("home")
    }

    var sortPriority: Int {
        let text = "\(displayName) \(summary)".lowercased()
        if text.contains("home") { return 0 }
        if text.contains("side") || text.contains("power") { return 1 }
        if text.contains("lock") { return 2 }
        if text.contains("siri") { return 3 }
        if text.contains("menu") { return 4 }
        if text.contains("play") || text.contains("pause") { return 5 }
        if text.contains("screenshot") || text.contains("capture") { return 6 }
        if text.contains("keyboard") { return 7 }
        if text.contains("pointer") || text.contains("mouse") || text.contains("trackpad") { return 8 }
        if text.contains("shake") { return 9 }
        return 100
    }
}

@MainActor
@Observable
final class DeviceState {
    let id: String
    let descriptor: DeviceDescriptor

    var isConnected = false
    var isConnecting = false
    var fps = 0.0
    var latencyMs = 0.0
    var lastError: String?
    var currentFrame: DeviceFrame?
    var simulatorDisplayBridge: PrivateSimulatorDisplayBridge?
    var availableSimulatorControls: [SimulatorChromeControl] = []
    var isBuildingApp = false
    var privateDisplayReady = false
    var privateDisplayStatus: String?
    var lastFrameAt: CFTimeInterval = 0
    var displayAspectRatio: CGFloat
    var currentPID: pid_t?
    var storageSnapshot: StorageSnapshot?
    var isRefreshingStorage: Bool = false
    var memorySamples: [MemorySample] = []
    var latestMemoryMB: Double?
    var cpuSamples: [CPUSample] = []
    var latestCPUPercent: Double?
    var latestThreadCount: Int?
    var networkRequests: [NetworkRequest] = []
    var networkError: String?
    var networkEnabled: Bool = false

    private var recentFrameTimes: [CFTimeInterval] = []

    init(descriptor: DeviceDescriptor) {
        id = descriptor.id
        self.descriptor = descriptor
        displayAspectRatio = descriptor.defaultAspectRatio
    }

    func appendMemorySample(_ sample: MemorySample) {
        memorySamples.append(sample)
        if memorySamples.count > 120 {
            memorySamples.removeFirst(memorySamples.count - 120)
        }
        latestMemoryMB = sample.footprintMB
    }

    func appendCPUSample(_ sample: CPUSample) {
        cpuSamples.append(sample)
        if cpuSamples.count > 120 {
            cpuSamples.removeFirst(cpuSamples.count - 120)
        }
        latestCPUPercent = sample.cpuPercent
        latestThreadCount = sample.threadCount
    }

    func appendNetworkRequest(_ request: NetworkRequest) {
        if let idx = networkRequests.firstIndex(where: { $0.id == request.id }) {
            networkRequests[idx] = request
        } else {
            networkRequests.append(request)
        }
        if networkRequests.count > 500 {
            networkRequests.removeFirst(networkRequests.count - 500)
        }
    }

    func clearNetworkRequests() {
        networkRequests.removeAll()
    }

    func updateNetworkStatus(_ status: NetworkStatus) {
        switch status {
        case .enabled:
            networkEnabled = true
            networkError = nil
        case .mitmproxyMissing:
            networkEnabled = false
            networkError = NetworkMonitorError.mitmproxyMissing.localizedDescription
        case let .failed(message):
            networkEnabled = false
            networkError = message
        }
    }

    func noteFrame(_ frame: DeviceFrame, at timestamp: CFTimeInterval = CACurrentMediaTime()) {
        currentFrame = frame
        lastFrameAt = timestamp

        if let dims = frame.dimensions, dims.height > 0 {
            let newRatio = CGFloat(dims.width) / CGFloat(dims.height)
            if abs(newRatio - displayAspectRatio) > 0.001 {
                displayAspectRatio = newRatio
            }
        }
        recentFrameTimes.append(timestamp)
        recentFrameTimes = recentFrameTimes.suffix(30)

        if let first = recentFrameTimes.first, recentFrameTimes.count > 1 {
            let elapsed = max(timestamp - first, 0.001)
            fps = Double(recentFrameTimes.count - 1) / elapsed
        }

        latencyMs = max(0, (CACurrentMediaTime() - timestamp) * 1000)
        lastError = nil
    }

    func noteConnected() {
        isConnecting = false
        isConnected = true
        lastError = nil
    }

    func noteDisconnected() {
        isConnecting = false
        isConnected = false
        availableSimulatorControls = []
    }

    func noteError(_ error: Error) {
        isConnecting = false
        isConnected = false
        lastError = Self.describe(error)
        print("DeviceState error [\(descriptor.displayName)]: \(lastError ?? String(describing: error))")
    }

    private static func describe(_ error: Error) -> String {
        if let rpcError = error as? RPCError {
            let message = rpcError.message.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "gRPC \(rpcError.code)" : "gRPC \(rpcError.code): \(message)"
        }

        return error.localizedDescription
    }
}

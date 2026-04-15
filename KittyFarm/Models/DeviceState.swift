import Foundation
import GRPCCore
import Metal
import Observation
import QuartzCore

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
    var isBuildingApp = false
    var privateDisplayReady = false
    var privateDisplayStatus: String?
    var lastFrameAt: CFTimeInterval = 0
    var displayAspectRatio: CGFloat

    private var recentFrameTimes: [CFTimeInterval] = []

    init(descriptor: DeviceDescriptor) {
        id = descriptor.id
        self.descriptor = descriptor
        displayAspectRatio = descriptor.defaultAspectRatio
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

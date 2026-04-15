import SwiftUI

struct MetricsOverlay: View {
    let state: DeviceState
    let isLeader: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isLeader ? "Leader" : state.descriptor.platform.rawValue)
                .font(.caption.weight(.semibold))

            if state.simulatorDisplayBridge != nil {
                Label("Private view", systemImage: "iphone")
                Label(
                    state.privateDisplayStatus ?? (state.privateDisplayReady ? "Private display ready" : "Starting private attach"),
                    systemImage: state.privateDisplayReady ? "checkmark.circle" : "hourglass"
                )
            } else {
                Label("\(Int(state.fps.rounded())) fps", systemImage: "speedometer")
                Label("\(Int(state.latencyMs.rounded())) ms", systemImage: "timer")
            }
        }
        .font(.caption2.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

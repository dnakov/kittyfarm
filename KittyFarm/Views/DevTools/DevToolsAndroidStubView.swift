import SwiftUI

struct DevToolsAndroidStubView: View {
    let feature: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "smartphone")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text("Android \(feature) inspection — coming soon")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

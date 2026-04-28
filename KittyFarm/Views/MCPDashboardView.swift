import SwiftUI

struct MCPDashboardView: View {
    @Bindable var store: KittyFarmStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "MCP Server",
                    isOn: Binding(
                        get: { store.isLocalControlAPIEnabled },
                        set: { isEnabled in
                            Task { await store.setLocalControlAPIEnabled(isEnabled) }
                        }
                    )
                )
                .toggleStyle(.switch)

                LabeledContent("Address") {
                    Text(store.localControlMCPURL)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(store.isLocalControlAPIEnabled ? .primary : .secondary)
                        .textSelection(.enabled)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Add KittyFarm MCP")
                    .font(.headline)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(MCPConfigurationTarget.allCases) { target in
                        Button {
                            store.installMCPConfiguration(for: target)
                        } label: {
                            Label(target.buttonTitle, systemImage: target.icon)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(!store.isLocalControlAPIEnabled)
                        .help(target.configPath.path)
                    }
                }
            }

            if !store.mcpDashboardStatus.isEmpty {
                Text(store.mcpDashboardStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .transition(.opacity)
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .animation(.smooth(duration: 0.2), value: store.mcpDashboardStatus)
        .animation(.smooth(duration: 0.2), value: store.isLocalControlAPIEnabled)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "hammer")
                .font(.title2)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("MCP Dashboard")
                    .font(.title2.weight(.semibold))
                Text("Expose KittyFarm tools to local model clients.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}

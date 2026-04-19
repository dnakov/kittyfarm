import SwiftUI

struct BottomPanelView: View {
    @Bindable var store: KittyFarmStore
    @Namespace private var tabNamespace

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()

            ZStack {
                switch store.bottomPanel {
                case .logs:
                    BuildLogPanelView(store: store)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .leading)),
                            removal: .opacity.combined(with: .move(edge: .trailing))
                        ))
                case .tests:
                    TestScriptView(store: store)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .trailing)),
                            removal: .opacity.combined(with: .move(edge: .leading))
                        ))
                case .network:
                    NetworkPanelView(store: store)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .leading)),
                            removal: .opacity.combined(with: .move(edge: .trailing))
                        ))
                case .performance:
                    PerformancePanelView(store: store)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .trailing)),
                            removal: .opacity.combined(with: .move(edge: .leading))
                        ))
                case .memory:
                    MemoryPanelView(store: store)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .leading)),
                            removal: .opacity.combined(with: .move(edge: .trailing))
                        ))
                case .storage:
                    StoragePanelView(store: store)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .trailing)),
                            removal: .opacity.combined(with: .move(edge: .leading))
                        ))
                case .hidden:
                    EmptyView()
                }
            }
            .animation(.smooth(duration: 0.3), value: store.bottomPanel)
        }
        .frame(minHeight: 200, idealHeight: 260, maxHeight: .infinity)
        .background(.ultraThickMaterial)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton(.logs, title: "Build Log", icon: "doc.plaintext") {
                store.bottomPanel = .logs
            }
            tabButton(.tests, title: "Tests", icon: "checklist") {
                store.bottomPanel = .tests
            }
            tabButton(.network, title: "Network", icon: "network") {
                store.bottomPanel = .network
            }
            tabButton(.performance, title: "Performance", icon: "speedometer") {
                store.bottomPanel = .performance
            }
            tabButton(.memory, title: "Memory", icon: "memorychip") {
                store.bottomPanel = .memory
            }
            tabButton(.storage, title: "Storage", icon: "internaldrive") {
                store.bottomPanel = .storage
            }

            Spacer()

            Button {
                withAnimation(.smooth(duration: 0.35)) {
                    store.bottomPanel = .hidden
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .help("Hide panel")
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(.bar)
    }

    @ViewBuilder
    private func tabButton(_ panel: BottomPanel, title: String, icon: String, action: @escaping () -> Void) -> some View {
        let isSelected = store.bottomPanel == panel
        Button {
            withAnimation(.smooth(duration: 0.25)) { action() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.caption.weight(isSelected ? .semibold : .regular))

                // Contextual badges
                if panel == .logs {
                    if store.buildErrorCount > 0 {
                        countPill(store.buildErrorCount, color: .red)
                            .transition(.scale.combined(with: .opacity))
                    } else if store.buildWarningCount > 0 {
                        countPill(store.buildWarningCount, color: .yellow)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                if panel == .tests, !store.testResults.isEmpty {
                    let failed = store.testResults.filter { $0.status == .failed }.count
                    if failed > 0 {
                        countPill(failed, color: .red)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        countPill(store.testResults.count, color: .green)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                if panel == .memory,
                   let mb = store.activeDevices.first?.latestMemoryMB {
                    labelPill(String(format: "%.0f MB", mb), color: .blue)
                        .transition(.scale.combined(with: .opacity))
                }
                if panel == .performance,
                   let cpu = store.activeDevices.first?.latestCPUPercent {
                    labelPill(String(format: "%.0f%%", cpu), color: cpu > 50 ? .orange : .gray)
                        .transition(.scale.combined(with: .opacity))
                }
                if panel == .network, store.networkRequestCount > 0 {
                    countPill(store.networkRequestCount, color: .gray)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .animation(.smooth, value: store.buildErrorCount)
            .animation(.smooth, value: store.buildWarningCount)
            .animation(.smooth, value: store.testResults.count)
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.background.secondary)
                    .matchedGeometryEffect(id: "selectedTab", in: tabNamespace)
            }
        }
    }

    private func countPill(_ count: Int, color: Color) -> some View {
        Text("\(count)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)
            .contentTransition(.numericText())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color, in: .capsule)
    }

    private func labelPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color, in: .capsule)
    }
}

import SwiftUI

struct ContentView: View {
    @Bindable var store: KittyFarmStore
    @State private var hoveredToolbarControl: ToolbarControl?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mainContent

                Divider()
                statusBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .animation(.smooth(duration: 0.35), value: store.shouldShowBottomPanel)
            .animation(.smooth(duration: 0.25), value: store.activeDevices.isEmpty)
            .animation(.smooth(duration: 0.25), value: store.isRunningBuildAndPlay)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem {
                    Button("MCP", systemImage: "hammer") {
                        store.isPresentingMCPDashboard = true
                    }
                    .help("MCP Dashboard")
                }

                ToolbarSpacer(.flexible)

                ToolbarItemGroup {
                    Button("Projects", systemImage: "folder") {
                        store.isPresentingProjectPicker = true
                    }

                    Button("Devices", systemImage: "rectangle.stack.badge.plus") {
                        store.isPresentingDevicePicker = true
                    }
                }

                ToolbarSpacer(.fixed)

                ToolbarItem {
                    HStack(spacing: 0) {
                        Button {
                            Task { await store.shutdownAll() }
                        } label: {
                            Image(systemName: "power")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(store.activeDevices.isEmpty ? Color.secondary : Color.red)
                                .frame(width: 32, height: 24)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.activeDevices.isEmpty)
                        .onHover { setToolbarHover(.shutdownAll, isHovering: $0) }
                        .help("Shutdown all simulators & emulators")

                        Divider()
                            .frame(height: 14)
                            .opacity(0.3)

                        Button {
                            Task { await store.toggleAllScreenRecordings() }
                        } label: {
                            Image(systemName: store.isAnyScreenRecording ? "stop.circle.fill" : "record.circle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(store.activeDevices.isEmpty ? Color.secondary : (store.isAnyScreenRecording ? Color.red : Color.primary))
                                .frame(width: 32, height: 24)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.activeDevices.isEmpty)
                        .onHover { setToolbarHover(.screenRecordings, isHovering: $0) }
                        .help(store.isAnyScreenRecording ? "Stop all screen recordings" : "Record all active devices separately")

                        Divider()
                            .frame(height: 14)
                            .opacity(0.3)

                        Button {
                            Task { await store.buildAndPlay() }
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(store.activeDevices.isEmpty || store.isRunningBuildAndPlay ? Color.secondary : Color.green)
                                .frame(width: 32, height: 24)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.activeDevices.isEmpty || store.isRunningBuildAndPlay)
                        .onHover { setToolbarHover(.buildAndPlay, isHovering: $0) }
                        .help(store.isRunningBuildAndPlay ? "Building…" : "Build & Play")
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
                    .overlay(alignment: .top) {
                        toolbarHoverBubble
                    }
                }

            }
        }
        .background {
            HardwareKeyboardCaptureView(store: store)
        }
        .task {
            await store.startLocalControlAPIIfNeeded()
            store.restoreSavedProjects()
            await store.refreshAvailableDevices()
            await store.restoreSavedDevices()
        }
        .sheet(isPresented: $store.isPresentingDevicePicker) {
            DevicePickerSheet(store: store)
                .frame(minWidth: 520, minHeight: 420)
        }
        .sheet(isPresented: $store.isPresentingProjectPicker) {
            ProjectPickerSheet(store: store)
                .frame(minWidth: 620, minHeight: 420)
        }
        .sheet(isPresented: $store.isPresentingMCPDashboard) {
            MCPDashboardView(store: store)
                .frame(minWidth: 520, minHeight: 360)
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if store.shouldShowBottomPanel {
            VSplitView {
                DeviceGridView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                BottomPanelView(store: store)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            DeviceGridView(store: store)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if store.isRunningBuildAndPlay {
                ProgressView()
                    .controlSize(.small)
                    .transition(.scale.combined(with: .opacity))
            }

            Text(store.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if !store.buildLogs.isEmpty || store.isRunningBuildAndPlay {
                Text(store.buildSummaryText)
                    .font(.caption)
                    .foregroundStyle(
                        store.buildErrorCount > 0
                            ? Color.red
                            : (store.buildWarningCount > 0 ? Color.yellow : Color.secondary)
                    )
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }

            Spacer(minLength: 0)

            Text(store.localControlStatus)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help(store.localControlStatus)

            openerButton(
                panel: .logs,
                title: "Logs",
                icon: "doc.plaintext",
                badge: logsBadge
            )

            openerButton(
                panel: .tests,
                title: "Tests",
                icon: "checklist",
                badge: testsBadge
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 0))
    }

    @ViewBuilder
    private func openerButton(panel: BottomPanel, title: String, icon: String, badge: (count: Int, color: Color)?) -> some View {
        let isActive = store.bottomPanel == panel
        Button {
            withAnimation(.smooth(duration: 0.35)) {
                store.bottomPanel = isActive ? .hidden : panel
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.caption.weight(isActive ? .semibold : .regular))
                if let badge, badge.count > 0 {
                    Text("\(badge.count)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(badge.color, in: .capsule)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .animation(.smooth, value: badge?.count ?? 0)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .fixedSize()
    }

    private var logsBadge: (count: Int, color: Color)? {
        if store.buildErrorCount > 0 {
            return (store.buildErrorCount, .red)
        }
        if store.buildWarningCount > 0 {
            return (store.buildWarningCount, .yellow)
        }
        return nil
    }

    private var testsBadge: (count: Int, color: Color)? {
        guard !store.testResults.isEmpty else { return nil }
        let failed = store.testResults.filter { $0.status == .failed }.count
        if failed > 0 {
            return (failed, .red)
        }
        return (store.testResults.count, .green)
    }

    @ViewBuilder
    private var toolbarHoverBubble: some View {
        if let hoveredToolbarControl {
            Text(hoveredToolbarControl.title(for: store))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: .capsule)
                .offset(y: -34)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .allowsHitTesting(false)
                .zIndex(10)
        }
    }

    private func setToolbarHover(_ control: ToolbarControl, isHovering: Bool) {
        withAnimation(.smooth(duration: 0.12)) {
            hoveredToolbarControl = isHovering ? control : (hoveredToolbarControl == control ? nil : hoveredToolbarControl)
        }
    }
}

private enum ToolbarControl: Equatable {
    case shutdownAll
    case screenRecordings
    case buildAndPlay

    @MainActor
    func title(for store: KittyFarmStore) -> String {
        switch self {
        case .shutdownAll:
            return "Shutdown all devices"
        case .screenRecordings:
            return store.isAnyScreenRecording ? "Stop screen recordings" : "Record active devices separately"
        case .buildAndPlay:
            return store.isRunningBuildAndPlay ? "Build in progress" : "Build and launch apps"
        }
    }
}

private struct HardwareKeyboardCaptureView: NSViewRepresentable {
    let store: KittyFarmStore

    func makeNSView(context: Context) -> KeyboardCaptureNSView {
        let view = KeyboardCaptureNSView()
        view.store = store
        return view
    }

    func updateNSView(_ nsView: KeyboardCaptureNSView, context: Context) {
        nsView.store = store
    }
}

@MainActor
private final class KeyboardCaptureNSView: NSView {
    weak var store: KittyFarmStore?
    private var keyMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitorIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)

        if newWindow == nil, let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func installMonitorIfNeeded() {
        guard keyMonitor == nil else {
            return
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self,
                  let store = self.store,
                  self.window?.isKeyWindow == true else {
                return event
            }

            let handled = store.handleHardwareKeyboardEvent(event)
            return handled ? nil : event
        }
    }
}

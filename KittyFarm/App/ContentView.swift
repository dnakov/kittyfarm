import SwiftUI

struct ContentView: View {
    @Bindable var store: KittyFarmStore

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
                        .help("Shutdown all simulators & emulators")

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
                        .help(store.isRunningBuildAndPlay ? "Building…" : "Build & Play")
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
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

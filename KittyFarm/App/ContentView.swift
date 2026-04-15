import SwiftUI

struct ContentView: View {
    @Bindable var store: KittyFarmStore

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mainContent

                if !store.activeDevices.isEmpty || store.isRunningBuildAndPlay {
                    Divider()
                    statusBar
                }
            }
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
        if store.shouldShowBuildLogs {
            VSplitView {
                DeviceGridView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                BuildLogPanelView(store: store)
                    .frame(minHeight: 180, idealHeight: 240, maxHeight: .infinity)
            }
        } else {
            DeviceGridView(store: store)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if store.isRunningBuildAndPlay {
                ProgressView()
                    .controlSize(.small)
            }

            Text(store.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if !store.buildLogs.isEmpty || store.isRunningBuildAndPlay {
                Label("\(store.buildWarningCount)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(store.buildWarningCount == 0 ? Color.secondary : Color.yellow)
                    .fixedSize()

                Label("\(store.buildErrorCount)", systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(store.buildErrorCount == 0 ? Color.secondary : Color.red)
                    .fixedSize()

                Text(store.buildSummaryText)
                    .font(.caption)
                    .foregroundStyle(
                        store.buildErrorCount > 0
                            ? Color.red
                            : (store.buildWarningCount > 0 ? Color.yellow : Color.secondary)
                    )
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button(store.shouldShowBuildLogs ? "Hide Logs" : "Show Logs") {
                    store.toggleBuildLogs()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .fixedSize()
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 0))
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

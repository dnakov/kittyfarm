import SwiftUI

struct DevicePaneView: View {
    let state: DeviceState
    let isLeader: Bool
    @Bindable var store: KittyFarmStore
    @Binding var draggedDeviceID: String?

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity)
                .opacity(isHovering ? 1 : 0)
                .animation(.smooth(duration: 0.25), value: isHovering)

            displayArea
                .padding(.horizontal, 2)

            detailsView
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(isHovering ? 1 : 0)
                .animation(.smooth(duration: 0.25), value: isHovering)
        }
        .padding(8)
        .glassEffect(
            isHovering ? .regular : .identity,
            in: .rect(cornerRadius: 12, style: .continuous)
        )
        .opacity(draggedDeviceID == state.id ? 0.35 : 1.0)
        .animation(.smooth(duration: 0.2), value: draggedDeviceID == state.id)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if !isHovering {
                    withAnimation(.smooth(duration: 0.25)) {
                        isHovering = true
                    }
                }
            case .ended:
                withAnimation(.smooth(duration: 0.25)) {
                    isHovering = false
                }
            }
        }
        .contextMenu {
            Button("Remove Device") {
                Task {
                    await store.removeDevice(state)
                }
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerView: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 20)
                .contentShape(Rectangle())
                .onDrag {
                    draggedDeviceID = state.id
                    return NSItemProvider(object: state.id as NSString)
                }
                .help("Drag to reorder")

            Text(state.descriptor.displayName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            connectionBadge

            Button {
                Task { await store.pressHomeButton(on: state) }
            } label: {
                Image(systemName: "house.fill")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(!state.isConnected)
            .help("Press Home")

            if state.descriptor.platform == .iOSSimulator {
                ForEach(state.availableSimulatorControls.filter { !$0.isHomeLike }) { control in
                    Button {
                        Task { await store.triggerSimulatorControl(control, on: state) }
                    } label: {
                        Image(systemName: control.systemImage)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(!state.isConnected)
                    .help(control.helpText)
                }
            }

            Button {
                Task { await store.rotateDeviceRight(on: state) }
            } label: {
                Image(systemName: "rotate.right.fill")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(!state.isConnected)
            .help("Rotate Right")

            Button {
                Task { await store.buildAndPlay(for: state) }
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(state.isBuildingApp || store.isRunningBuildAndPlay)
            .help("Build & Play on this device")
        }
    }

    // MARK: - Connection Badge

    @ViewBuilder
    private var connectionBadge: some View {
        Group {
            if state.isBuildingApp || state.isConnecting {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 6, height: 6)
            }
        }
        .help(connectionLabel)
        .animation(.smooth, value: state.isConnected)
        .animation(.smooth, value: state.isConnecting)
        .animation(.smooth, value: state.isBuildingApp)
    }

    private var connectionColor: Color {
        if state.isConnected { return .green }
        if state.lastError != nil { return .red }
        return .gray
    }

    private var connectionLabel: String {
        if state.isBuildingApp { return "Building…" }
        if state.isConnecting { return "Connecting…" }
        if state.isConnected { return "Connected" }
        if state.lastError != nil { return "Error" }
        return "Idle"
    }

    // MARK: - Display

    private var hasContent: Bool {
        state.currentFrame != nil || state.simulatorDisplayBridge != nil
    }

    @ViewBuilder
    private var displayArea: some View {
        DeviceShellView(descriptor: state.descriptor) {
            if hasContent {
                displaySurface
            } else {
                Color.black
                    .overlay {
                        ProgressView()
                            .tint(.white)
                    }
            }
        }
    }

    @ViewBuilder
    private var displaySurface: some View {
        GeometryReader { geo in
            let fittedSize = fittedDisplaySize(
                in: geo.size,
                aspectRatio: state.displayAspectRatio
            )

            ZStack {
                if let bridge = state.simulatorDisplayBridge {
                    SimulatorDisplayView(bridge: bridge)
                        .frame(width: fittedSize.width, height: fittedSize.height)
                        .allowsHitTesting(false)
                        .opacity(0.001)
                }

                MetalFrameView(state: state)
                    .frame(width: fittedSize.width, height: fittedSize.height)

                MouseTouchCaptureView(
                    isKeyboardActive: store.activeInputDeviceID == state.id,
                    onActivate: {
                        store.setActiveInputDevice(state)
                    },
                    onTouch: { location, size, phase in
                        Task {
                            await store.replicateTouch(from: state, location: location, in: size, phase: phase)
                        }
                    }
                )
                .frame(width: fittedSize.width, height: fittedSize.height)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func fittedDisplaySize(in availableSize: CGSize, aspectRatio: CGFloat) -> CGSize {
        guard availableSize.width > 0, availableSize.height > 0 else {
            return .zero
        }

        let safeRatio = max(aspectRatio, 0.001)
        let availableRatio = availableSize.width / availableSize.height

        if availableRatio > safeRatio {
            let height = availableSize.height
            return CGSize(width: height * safeRatio, height: height)
        } else {
            let width = availableSize.width
            return CGSize(width: width, height: width / safeRatio)
        }
    }

    // MARK: - Details

    @ViewBuilder
    private var detailsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label {
                    Text(state.descriptor.platform.rawValue)
                } icon: {
                    Image(systemName: platformIcon)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Spacer(minLength: 0)

                if state.simulatorDisplayBridge == nil, state.isConnected {
                    HStack(spacing: 8) {
                        Label("\(Int(state.fps.rounded())) fps", systemImage: "speedometer")
                        Label("\(Int(state.latencyMs.rounded())) ms", systemImage: "timer")
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }

                if state.simulatorDisplayBridge != nil {
                    Label(
                        state.privateDisplayReady ? "Live" : "Starting…",
                        systemImage: state.privateDisplayReady ? "video.fill" : "hourglass"
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            if let lastError = state.lastError {
                Text(lastError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.smooth(duration: 0.25), value: state.lastError)
    }

    private var platformIcon: String {
        switch state.descriptor.platform {
        case .iOSSimulator:
            return "iphone"
        case .androidEmulator:
            return "phone"
        }
    }
}

private struct MouseTouchCaptureView: NSViewRepresentable {
    let isKeyboardActive: Bool
    let onActivate: @MainActor () -> Void
    let onTouch: @MainActor (CGPoint, CGSize, NormalizedTouch.Phase) -> Void

    func makeNSView(context: Context) -> TouchView {
        let view = TouchView()
        view.isKeyboardActive = isKeyboardActive
        view.onActivate = onActivate
        view.onTouch = onTouch
        return view
    }

    func updateNSView(_ nsView: TouchView, context: Context) {
        nsView.isKeyboardActive = isKeyboardActive
        nsView.onActivate = onActivate
        nsView.onTouch = onTouch
    }
}

@MainActor
private final class TouchView: NSView {
    var isKeyboardActive = false
    var onActivate: (@MainActor () -> Void)?
    var onTouch: (@MainActor (CGPoint, CGSize, NormalizedTouch.Phase) -> Void)?

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        window?.makeFirstResponder(self)
        emit(event, phase: .began)
    }

    override func mouseDragged(with event: NSEvent) {
        emit(event, phase: .moved)
    }

    override func mouseUp(with event: NSEvent) {
        emit(event, phase: .ended)
    }

    private func emit(_ event: NSEvent, phase: NormalizedTouch.Phase) {
        let location = convert(event.locationInWindow, from: nil)
        onTouch?(location, bounds.size, phase)
    }
}

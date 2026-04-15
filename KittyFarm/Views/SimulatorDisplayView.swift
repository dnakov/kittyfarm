import AppKit
import SwiftUI

struct SimulatorDisplayView: NSViewRepresentable {
    let bridge: PrivateSimulatorDisplayBridge

    func makeNSView(context: Context) -> NSView {
        let hostView = SimulatorDisplayHostView()
        hostView.configure(with: bridge)
        return hostView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let hostView = nsView as? SimulatorDisplayHostView else {
            return
        }
        hostView.configure(with: bridge)
    }
}

private final class SimulatorDisplayHostView: NSView {
    private weak var embeddedDisplayView: NSView?
    private var bridge: PrivateSimulatorDisplayBridge?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func layout() {
        super.layout()
        embeddedDisplayView?.frame = bounds
        bridge?.activateDisplayIfNeeded()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        embeddedDisplayView?.frame = bounds
        bridge?.activateDisplayIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        embeddedDisplayView?.frame = bounds
        bridge?.activateDisplayIfNeeded()
    }

    func configure(with bridge: PrivateSimulatorDisplayBridge) {
        self.bridge = bridge

        let displayView = bridge.displayView
        if displayView.superview !== self {
            displayView.removeFromSuperview()
            displayView.frame = bounds
            displayView.autoresizingMask = [.width, .height]
            displayView.alphaValue = 1.0
            addSubview(displayView)
        }

        displayView.alphaValue = 1.0
        embeddedDisplayView = displayView
        needsLayout = true
        layoutSubtreeIfNeeded()
        bridge.activateDisplayIfNeeded()
    }
}

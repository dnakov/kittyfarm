import AppKit
import SwiftUI

struct FlamegraphView: View {
    let threads: [FlamegraphThread]

    @State private var selectedThreadID: UUID?
    @State private var searchText: String = ""
    @State private var viewportXMin: Double = 0.0
    @State private var viewportXMax: Double = 1.0
    @State private var selectedCellIndex: Int?

    private var hasZoom: Bool { viewportXMin > 0 || viewportXMax < 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            controls
            if let thread = currentThread {
                FlamegraphCanvas(
                    thread: thread,
                    searchText: searchText,
                    viewportXMin: $viewportXMin,
                    viewportXMax: $viewportXMax,
                    selectedCellIndex: $selectedCellIndex
                )
                if let idx = selectedCellIndex, thread.cells.indices.contains(idx) {
                    selectedDetails(thread: thread, cellIndex: idx)
                        .transition(.opacity)
                }
            } else {
                Text("No samples to display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { ensureSelection() }
        .onChange(of: threads) { _, _ in
            ensureSelection()
            resetView()
        }
        .onChange(of: selectedThreadID) { _, _ in
            resetView()
        }
    }

    private var currentThread: FlamegraphThread? {
        if let id = selectedThreadID, let match = threads.first(where: { $0.id == id }) {
            return match
        }
        return threads.first
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if threads.count > 1 {
                Picker("Thread", selection: Binding(
                    get: { selectedThreadID ?? threads.first?.id ?? UUID() },
                    set: { selectedThreadID = $0 }
                )) {
                    ForEach(threads) { thread in
                        Text("\(thread.label) · \(thread.totalSamples)").tag(thread.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 320)
            }

            if hasZoom {
                Button("Reset zoom") { resetView() }
                    .controlSize(.small)
                    .help("Reset to 100% — also fits with double-click background")
            }

            Spacer()

            Image(systemName: "magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("Highlight", text: $searchText, prompt: Text("Highlight…"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func selectedDetails(thread: FlamegraphThread, cellIndex: Int) -> some View {
        let cell = thread.cells[cellIndex]
        let pct = Double(cell.sampleCount) / Double(max(1, thread.totalSamples)) * 100.0
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(cell.symbol)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .lineLimit(2)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text("\(cell.sampleCount) samples")
                    Text(String(format: "(%.1f%%)", pct))
                    if let module = cell.module {
                        Text("·")
                        Text(module).foregroundStyle(.tertiary)
                    }
                    Text("·")
                    Text("depth \(cell.depth)")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Zoom to frame") {
                zoom(to: cell)
            }
            .controlSize(.small)
            .keyboardShortcut("f", modifiers: [])
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func zoom(to cell: FlamegraphCell) {
        withAnimation(.easeOut(duration: 0.18)) {
            viewportXMin = cell.xRatio
            viewportXMax = min(1.0, cell.xRatio + cell.widthRatio)
        }
    }

    private func resetView() {
        withAnimation(.easeOut(duration: 0.18)) {
            viewportXMin = 0
            viewportXMax = 1
            selectedCellIndex = nil
        }
    }

    private func ensureSelection() {
        if let id = selectedThreadID, threads.contains(where: { $0.id == id }) {
            return
        }
        selectedThreadID = threads.first?.id
    }
}

// MARK: - Canvas

private struct FlamegraphCanvas: View {
    let thread: FlamegraphThread
    let searchText: String
    @Binding var viewportXMin: Double
    @Binding var viewportXMax: Double
    @Binding var selectedCellIndex: Int?

    private static let rowHeight: CGFloat = 18
    private static let topPadding: CGFloat = 2
    private static let rulerHeight: CGFloat = 22
    private static let samplingIntervalMs: Double = 1.0   // `/usr/bin/sample` default

    @State private var hoveredCellIndex: Int?
    @State private var hoverPoint: CGPoint = .zero
    @State private var dragStartViewport: (Double, Double)?

    private var framesOriginY: CGFloat { Self.topPadding + Self.rulerHeight }

    var body: some View {
        let totalHeight = framesOriginY + CGFloat(thread.maxDepth + 1) * Self.rowHeight + 8

        return GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                Canvas(opaque: false, rendersAsynchronously: false) { ctx, _ in
                    drawRuler(ctx: ctx, size: size)
                    drawCells(ctx: ctx, size: size)
                }
                .frame(width: size.width, height: totalHeight)
                .background(Color(nsColor: .underPageBackgroundColor))

                // Catches AppKit wheel events and routes them as zoom/pan.
                WheelEventCatcher(onWheel: { event, location in
                    handleWheel(event: event, locationInView: location, size: size)
                })
                .frame(width: size.width, height: totalHeight)
                .allowsHitTesting(true)

                if let idx = hoveredCellIndex, thread.cells.indices.contains(idx) {
                    tooltip(for: thread.cells[idx])
                        .position(tooltipPosition(at: hoverPoint, in: size))
                        .allowsHitTesting(false)
                }

                cursorGuide(at: hoverPoint, height: totalHeight)
            }
            .frame(width: size.width, height: max(totalHeight, size.height), alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(point):
                    hoverPoint = point
                    hoveredCellIndex = cellIndex(at: point, in: size)
                case .ended:
                    hoveredCellIndex = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        if dragStartViewport == nil {
                            dragStartViewport = (viewportXMin, viewportXMax)
                        }
                        guard let (startMin, startMax) = dragStartViewport else { return }
                        let dxRatio = Double(value.translation.width / size.width) * (startMax - startMin)
                        var newMin = startMin - dxRatio
                        var newMax = startMax - dxRatio
                        // Clamp to [0,1] keeping width constant.
                        if newMin < 0 { newMax += -newMin; newMin = 0 }
                        if newMax > 1 { newMin -= newMax - 1; newMax = 1 }
                        viewportXMin = max(0, newMin)
                        viewportXMax = min(1, newMax)
                    }
                    .onEnded { _ in dragStartViewport = nil }
            )
            .gesture(MagnifyGesture()
                .onChanged { value in
                    let factor = 1.0 / max(0.1, value.magnification)
                    let center = (Double(hoverPoint.x / size.width)) * (viewportXMax - viewportXMin) + viewportXMin
                    applyZoom(factor: factor, aroundXRatio: center)
                }
            )
            .onTapGesture(count: 2) { location in
                if let idx = cellIndex(at: location, in: size) {
                    let cell = thread.cells[idx]
                    selectedCellIndex = idx
                    withAnimation(.easeOut(duration: 0.18)) {
                        viewportXMin = cell.xRatio
                        viewportXMax = min(1, cell.xRatio + cell.widthRatio)
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.18)) {
                        viewportXMin = 0
                        viewportXMax = 1
                    }
                }
            }
            .onTapGesture {
                if let idx = hoveredCellIndex {
                    selectedCellIndex = idx
                } else {
                    selectedCellIndex = nil
                }
            }
        }
        .frame(minHeight: totalHeight)
    }

    // MARK: Drawing

    private func drawRuler(ctx: GraphicsContext, size: CGSize) {
        let viewportWidth = viewportXMax - viewportXMin
        let totalMs = Double(thread.totalSamples) * Self.samplingIntervalMs
        let visibleMs = max(0.001, totalMs * viewportWidth)
        let pixelsPerMs = Double(size.width) / visibleMs

        // Aim for major ticks ~110 px apart — same density as Chrome DevTools.
        let targetMsPerTick = 110.0 / pixelsPerMs
        let majorInterval = niceTickInterval(forTarget: targetMsPerTick)
        let minorInterval = majorInterval / 5.0       // 5 minors per major

        let viewportStartMs = viewportXMin * totalMs
        let viewportEndMs = viewportXMax * totalMs

        // Background under ruler — slightly stronger than the canvas backdrop
        // so the labels read clearly.
        let rulerRect = CGRect(x: 0, y: 0, width: size.width, height: framesOriginY)
        ctx.fill(Path(rulerRect), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.85)))

        // Minor ticks
        var ms = floor(viewportStartMs / minorInterval) * minorInterval
        while ms <= viewportEndMs + minorInterval {
            let xRatio = (ms / totalMs - viewportXMin) / viewportWidth
            let x = CGFloat(xRatio) * size.width
            if x >= 0, x <= size.width {
                ctx.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: x, y: framesOriginY - 4))
                        p.addLine(to: CGPoint(x: x, y: framesOriginY))
                    },
                    with: .color(.secondary.opacity(0.4)),
                    lineWidth: 0.5
                )
            }
            ms += minorInterval
        }

        // Major ticks + labels (and faint guidelines down through the frames)
        ms = floor(viewportStartMs / majorInterval) * majorInterval
        while ms <= viewportEndMs + majorInterval {
            let xRatio = (ms / totalMs - viewportXMin) / viewportWidth
            let x = CGFloat(xRatio) * size.width
            if x >= 0, x <= size.width {
                ctx.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: x, y: framesOriginY - 8))
                        p.addLine(to: CGPoint(x: x, y: framesOriginY))
                    },
                    with: .color(.secondary),
                    lineWidth: 1.0
                )
                // Faint guideline through the frame area, behind the cells.
                ctx.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: x, y: framesOriginY))
                        p.addLine(to: CGPoint(x: x, y: size.height))
                    },
                    with: .color(.primary.opacity(0.06)),
                    lineWidth: 0.5
                )
                let label = formatMs(ms, interval: majorInterval)
                let resolved = ctx.resolve(Text(label)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary))
                ctx.draw(resolved, at: CGPoint(x: x + 3, y: 3), anchor: .topLeading)
            }
            ms += majorInterval
        }

        // Bottom border separating ruler from frame area.
        ctx.stroke(
            Path { p in
                p.move(to: CGPoint(x: 0, y: framesOriginY))
                p.addLine(to: CGPoint(x: size.width, y: framesOriginY))
            },
            with: .color(.primary.opacity(0.18)),
            lineWidth: 0.5
        )

        // Cursor time readout in the ruler when hovering.
        if let _ = hoveredCellIndex {
            let cursorMs = viewportStartMs + (viewportEndMs - viewportStartMs) * Double(hoverPoint.x / size.width)
            let label = formatMs(cursorMs, interval: minorInterval)
            let pillText = ctx.resolve(Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white))
            let pillSize = pillText.measure(in: CGSize(width: 100, height: 20))
            let padding: CGFloat = 4
            let pillRect = CGRect(
                x: hoverPoint.x - pillSize.width / 2 - padding,
                y: 1,
                width: pillSize.width + padding * 2,
                height: pillSize.height + 2
            )
            let clamped = CGRect(
                x: max(0, min(size.width - pillRect.width, pillRect.minX)),
                y: pillRect.minY,
                width: pillRect.width,
                height: pillRect.height
            )
            ctx.fill(Path(roundedRect: clamped, cornerRadius: 3), with: .color(.accentColor))
            ctx.draw(pillText, at: CGPoint(x: clamped.midX, y: clamped.midY), anchor: .center)
        }
    }

    private func niceTickInterval(forTarget target: Double) -> Double {
        guard target > 0, target.isFinite else { return 1.0 }
        let exponent = floor(log10(target))
        let mag = pow(10.0, exponent)
        let normalized = target / mag
        let nice: Double
        if normalized < 1.5 { nice = 1.0 }
        else if normalized < 3.5 { nice = 2.0 }
        else if normalized < 7.5 { nice = 5.0 }
        else { nice = 10.0 }
        return nice * mag
    }

    private func formatMs(_ ms: Double, interval: Double) -> String {
        if interval >= 1000 {
            return String(format: "%.1fs", ms / 1000)
        }
        if interval >= 1 {
            return String(format: "%.0f ms", ms)
        }
        if interval >= 0.1 {
            return String(format: "%.1f ms", ms)
        }
        return String(format: "%.2f ms", ms)
    }

    private func drawCells(ctx: GraphicsContext, size: CGSize) {
        let width = size.width
        let needle = searchText.lowercased()
        let highlight = !needle.isEmpty
        let viewportWidth = max(0.0001, viewportXMax - viewportXMin)

        for (index, cell) in thread.cells.enumerated() {
            // Cull cells outside viewport
            if cell.xRatio + cell.widthRatio < viewportXMin { continue }
            if cell.xRatio > viewportXMax { continue }

            let projXRatio = (cell.xRatio - viewportXMin) / viewportWidth
            let projWRatio = cell.widthRatio / viewportWidth
            let rect = CGRect(
                x: projXRatio * width,
                y: framesOriginY + CGFloat(cell.depth) * Self.rowHeight,
                width: max(0, projWRatio * width),
                height: Self.rowHeight - 1
            )
            if rect.width < 0.6 {
                continue
            }
            let isSelected = selectedCellIndex == index
            let isHovered = hoveredCellIndex == index
            let dim = highlight && !cell.symbol.lowercased().contains(needle)
            let fill = color(for: cell, isHovered: isHovered, isSelected: isSelected, dim: dim)
            ctx.fill(Path(rect), with: .color(fill))
            ctx.stroke(Path(rect), with: .color(.black.opacity(isSelected ? 0.6 : 0.18)), lineWidth: isSelected ? 1.4 : 0.5)

            if rect.width > 36 {
                let inset = rect.insetBy(dx: 4, dy: 1)
                let resolved = ctx.resolve(Text(truncatedSymbol(for: cell, fittingWidth: inset.width))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.black.opacity(0.85)))
                ctx.draw(resolved, at: CGPoint(x: inset.minX, y: inset.minY), anchor: .topLeading)
            }
        }
    }

    private func color(for cell: FlamegraphCell, isHovered: Bool, isSelected: Bool, dim: Bool) -> Color {
        let hash = cell.symbol.utf8.reduce(UInt32(2_166_136_261)) { acc, byte in
            (acc ^ UInt32(byte)) &* 16_777_619
        }
        let hueBand = Double(hash % 60) / 60.0
        let hue = 0.0 + hueBand * 0.12
        let sat = isSelected ? 0.95 : (isHovered ? 0.85 : 0.55)
        let bright = dim ? 0.55 : (isSelected ? 1.0 : (isHovered ? 1.0 : 0.95))
        return Color(hue: hue, saturation: sat, brightness: bright, opacity: dim ? 0.55 : 1.0)
    }

    private func truncatedSymbol(for cell: FlamegraphCell, fittingWidth: CGFloat) -> String {
        let approxCharsPerPoint = 1.0 / 6.5
        let maxChars = max(2, Int(fittingWidth * approxCharsPerPoint))
        if cell.symbol.count <= maxChars {
            return cell.symbol
        }
        return String(cell.symbol.prefix(max(1, maxChars - 1))) + "…"
    }

    @ViewBuilder
    private func cursorGuide(at point: CGPoint, height: CGFloat) -> some View {
        if hoveredCellIndex != nil {
            Rectangle()
                .fill(Color.accentColor.opacity(0.45))
                .frame(width: 1, height: height - framesOriginY)
                .position(x: point.x, y: framesOriginY + (height - framesOriginY) / 2)
                .allowsHitTesting(false)
        }
    }

    // MARK: Hit-testing

    private func cellIndex(at point: CGPoint, in size: CGSize) -> Int? {
        guard point.y >= framesOriginY else { return nil }   // ruler row, not a frame
        let row = Int((point.y - framesOriginY) / Self.rowHeight)
        guard row >= 0, row <= thread.maxDepth else { return nil }
        let viewportWidth = max(0.0001, viewportXMax - viewportXMin)
        let xRatio = viewportXMin + Double(point.x / size.width) * viewportWidth
        guard (0.0...1.0).contains(xRatio) else { return nil }
        for (idx, cell) in thread.cells.enumerated() where cell.depth == row {
            if cell.xRatio <= xRatio && xRatio < cell.xRatio + cell.widthRatio {
                return idx
            }
        }
        return nil
    }

    // MARK: Zoom / pan

    private func handleWheel(event: NSEvent, locationInView: CGPoint, size: CGSize) {
        // Trackpad and Magic Mouse populate scrollingDeltaY; classic wheel uses deltaY.
        let dy = abs(event.scrollingDeltaY) > 0 ? event.scrollingDeltaY : event.deltaY
        let dx = abs(event.scrollingDeltaX) > 0 ? event.scrollingDeltaX : event.deltaX
        let viewportWidth = viewportXMax - viewportXMin

        if event.modifierFlags.contains(.shift) || abs(dx) > abs(dy) {
            // Horizontal scroll = pan
            let panRatio = Double(dx / size.width) * viewportWidth
            applyPan(by: -panRatio)
            return
        }

        // Vertical wheel = zoom around cursor
        // Negative dy means scroll-down = zoom out (matches Chrome / Instruments)
        let factor = pow(1.10, -dy / 20.0)
        let centerXRatio = viewportXMin + Double(locationInView.x / size.width) * viewportWidth
        applyZoom(factor: factor, aroundXRatio: centerXRatio)
    }

    private func applyPan(by deltaXRatio: Double) {
        var newMin = viewportXMin + deltaXRatio
        var newMax = viewportXMax + deltaXRatio
        if newMin < 0 { newMax += -newMin; newMin = 0 }
        if newMax > 1 { newMin -= newMax - 1; newMax = 1 }
        viewportXMin = max(0, newMin)
        viewportXMax = min(1, newMax)
    }

    private func applyZoom(factor: Double, aroundXRatio center: Double) {
        let viewportWidth = viewportXMax - viewportXMin
        let newWidth = max(0.0005, min(1.0, viewportWidth * factor))   // 0.05% min ~ very deep zoom; 100% max
        let leftFraction = (center - viewportXMin) / max(0.0001, viewportWidth)
        var newMin = center - leftFraction * newWidth
        var newMax = newMin + newWidth
        if newMin < 0 { newMax += -newMin; newMin = 0 }
        if newMax > 1 { newMin -= newMax - 1; newMax = 1 }
        viewportXMin = max(0, newMin)
        viewportXMax = min(1, newMax)
    }

    // MARK: Tooltip

    @ViewBuilder
    private func tooltip(for cell: FlamegraphCell) -> some View {
        let pct = Double(cell.sampleCount) / Double(max(1, thread.totalSamples)) * 100.0
        VStack(alignment: .leading, spacing: 2) {
            Text(cell.symbol)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .lineLimit(3)
            HStack(spacing: 6) {
                Text("\(cell.sampleCount) samples")
                Text(String(format: "(%.1f%%)", pct))
                if let module = cell.module {
                    Text("·")
                    Text(module).foregroundStyle(.tertiary)
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(radius: 4, y: 2)
        .frame(maxWidth: 380, alignment: .leading)
    }

    private func tooltipPosition(at point: CGPoint, in size: CGSize) -> CGPoint {
        let estimatedWidth: CGFloat = 240
        let estimatedHeight: CGFloat = 48
        var x = point.x + 14 + estimatedWidth / 2
        var y = point.y + 14 + estimatedHeight / 2
        if x + estimatedWidth / 2 > size.width {
            x = point.x - 14 - estimatedWidth / 2
        }
        if y + estimatedHeight / 2 > size.height {
            y = point.y - 14 - estimatedHeight / 2
        }
        return CGPoint(x: x, y: y)
    }
}

// MARK: - AppKit wheel-event bridge

/// SwiftUI doesn't expose `scrollWheel(_:)`, and overlaying an NSView would
/// fight the SwiftUI canvas for click hit-testing. Instead, install a local
/// NSEvent monitor for `.scrollWheel` events and gate it on whether the
/// cursor is currently over our background view (which keeps the bounds we
/// care about and is in the proper window for coordinate conversion).
private struct WheelEventCatcher: NSViewRepresentable {
    let onWheel: (NSEvent, CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.trackedView = view
        context.coordinator.onWheel = onWheel
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onWheel = onWheel
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        weak var trackedView: NSView?
        var onWheel: ((NSEvent, CGPoint) -> Void)?
        private var monitor: Any?

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard
                    let self,
                    let view = self.trackedView,
                    let window = view.window,
                    event.window == window
                else { return event }

                let local = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(local) else { return event }

                self.onWheel?(event, local)
                return nil   // consume so the parent ScrollView doesn't also pan
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit { removeMonitor() }
    }
}

import AppKit
import SwiftUI

/// Time-ordered flame chart (Chrome-style). Unlike `FlamegraphView` (which
/// shows aggregated CPU shares), here X is real wall-clock time and the same
/// function called twice shows up as two separate rectangles.
struct FlameChartView: View {
    let threads: [FlameChartThread]
    let traceStartNs: UInt64
    let traceEndNs: UInt64

    @State private var selectedThreadID: UInt64?
    @State private var searchText: String = ""
    @State private var viewportStartNs: UInt64 = 0
    @State private var viewportEndNs: UInt64 = 1
    @State private var selectedCellID: UUID?

    private var hasZoom: Bool {
        viewportStartNs > traceStartNs || viewportEndNs < traceEndNs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            controls
            if let thread = currentThread {
                FlameChartCanvas(
                    thread: thread,
                    searchText: searchText,
                    viewportStartNs: $viewportStartNs,
                    viewportEndNs: $viewportEndNs,
                    selectedCellID: $selectedCellID
                )
                if let id = selectedCellID,
                   let cell = thread.cells.first(where: { $0.id == id }) {
                    selectedDetails(cell: cell)
                        .transition(.opacity)
                }
            } else {
                Text("No samples to display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { ensureSelection(); resetViewport() }
        .onChange(of: threads) { _, _ in ensureSelection(); resetViewport() }
        .onChange(of: selectedThreadID) { _, _ in resetViewport() }
    }

    private var currentThread: FlameChartThread? {
        if let id = selectedThreadID, let match = threads.first(where: { $0.id == id }) {
            return match
        }
        return threads.first
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if threads.count > 1 {
                Picker("Thread", selection: Binding(
                    get: { selectedThreadID ?? threads.first?.id ?? 0 },
                    set: { selectedThreadID = $0 }
                )) {
                    ForEach(threads) { thread in
                        Text("\(thread.label) · \(thread.sampleCount) samples").tag(thread.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 360)
            }
            if hasZoom {
                Button("Reset zoom") { resetViewport() }
                    .controlSize(.small)
            }
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.caption2).foregroundStyle(.secondary)
            TextField("Highlight", text: $searchText, prompt: Text("Highlight…"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func selectedDetails(cell: FlameChartCell) -> some View {
        let durationMs = Double(cell.durationNs) / 1_000_000.0
        let startMs = Double(cell.startNs - traceStartNs) / 1_000_000.0
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(cell.symbol)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .lineLimit(2)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(String(format: "%.3f ms", durationMs))
                    Text("·")
                    Text(String(format: "@ %.1f ms", startMs))
                    if let module = cell.module {
                        Text("·").foregroundStyle(.tertiary)
                        Text(module).foregroundStyle(.tertiary)
                    }
                    Text("·").foregroundStyle(.tertiary)
                    Text("depth \(cell.depth)").foregroundStyle(.tertiary)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Zoom to frame") {
                withAnimation(.easeOut(duration: 0.18)) {
                    viewportStartNs = cell.startNs
                    viewportEndNs = max(cell.endNs, cell.startNs + 1)
                }
            }
            .controlSize(.small)
            .keyboardShortcut("f", modifiers: [])
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func resetViewport() {
        withAnimation(.easeOut(duration: 0.18)) {
            viewportStartNs = traceStartNs
            viewportEndNs = max(traceEndNs, traceStartNs + 1)
            selectedCellID = nil
        }
    }

    private func ensureSelection() {
        if let id = selectedThreadID, threads.contains(where: { $0.id == id }) { return }
        selectedThreadID = threads.first?.id
    }
}

// MARK: - Canvas

private struct FlameChartCanvas: View {
    let thread: FlameChartThread
    let searchText: String
    @Binding var viewportStartNs: UInt64
    @Binding var viewportEndNs: UInt64
    @Binding var selectedCellID: UUID?

    private static let rowHeight: CGFloat = 18
    private static let topPadding: CGFloat = 2
    private static let rulerHeight: CGFloat = 22
    private var framesOriginY: CGFloat { Self.topPadding + Self.rulerHeight }

    @State private var hoveredCellID: UUID?
    @State private var hoverPoint: CGPoint = .zero
    @State private var dragStartViewport: (UInt64, UInt64)?

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

                WheelEventBridge(onWheel: { event, location in
                    handleWheel(event: event, locationInView: location, size: size)
                })
                .frame(width: size.width, height: totalHeight)

                if let id = hoveredCellID, let cell = thread.cells.first(where: { $0.id == id }) {
                    tooltip(for: cell)
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
                    hoveredCellID = cellID(at: point, in: size)
                case .ended:
                    hoveredCellID = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if dragStartViewport == nil {
                        dragStartViewport = (viewportStartNs, viewportEndNs)
                    }
                    guard let (startMin, startMax) = dragStartViewport else { return }
                    let span = Double(startMax - startMin)
                    let dxNs = Double(value.translation.width / size.width) * span
                    pan(byNs: -Int64(dxNs), startMin: startMin, startMax: startMax)
                }
                .onEnded { _ in dragStartViewport = nil }
            )
            .gesture(MagnifyGesture()
                .onChanged { value in
                    let factor = 1.0 / max(0.1, value.magnification)
                    let centerNs = nsAtPoint(hoverPoint.x, in: size)
                    applyZoom(factor: factor, aroundNs: centerNs)
                }
            )
            .onTapGesture(count: 2) { location in
                if let id = cellID(at: location, in: size),
                   let cell = thread.cells.first(where: { $0.id == id }) {
                    selectedCellID = id
                    withAnimation(.easeOut(duration: 0.18)) {
                        viewportStartNs = cell.startNs
                        viewportEndNs = max(cell.endNs, cell.startNs + 1)
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.18)) {
                        viewportStartNs = thread.startNs
                        viewportEndNs = thread.endNs
                    }
                }
            }
            .onTapGesture {
                selectedCellID = hoveredCellID
            }
        }
        .frame(minHeight: totalHeight)
    }

    // MARK: Drawing

    private func drawCells(ctx: GraphicsContext, size: CGSize) {
        let width = size.width
        let needle = searchText.lowercased()
        let highlight = !needle.isEmpty
        let viewportSpan = Double(viewportEndNs > viewportStartNs ? viewportEndNs - viewportStartNs : 1)

        for cell in thread.cells {
            if cell.endNs < viewportStartNs { continue }
            if cell.startNs > viewportEndNs { continue }

            let xStart = Double(cell.startNs > viewportStartNs ? cell.startNs - viewportStartNs : 0) / viewportSpan
            let xEnd = Double(min(cell.endNs, viewportEndNs) - viewportStartNs) / viewportSpan
            let rect = CGRect(
                x: xStart * width,
                y: framesOriginY + CGFloat(cell.depth) * Self.rowHeight,
                width: max(0, (xEnd - xStart) * width),
                height: Self.rowHeight - 1
            )
            if rect.width < 0.6 { continue }

            let isSelected = selectedCellID == cell.id
            let isHovered = hoveredCellID == cell.id
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

    private func drawRuler(ctx: GraphicsContext, size: CGSize) {
        let viewportSpanNs = viewportEndNs > viewportStartNs ? viewportEndNs - viewportStartNs : 1
        let visibleMs = Double(viewportSpanNs) / 1_000_000.0
        let pixelsPerMs = Double(size.width) / max(0.001, visibleMs)
        let targetMsPerTick = 110.0 / pixelsPerMs
        let majorInterval = niceTickInterval(forTarget: targetMsPerTick)
        let minorInterval = majorInterval / 5.0

        let viewportStartMs = Double(viewportStartNs - thread.startNs) / 1_000_000.0
        let viewportEndMs = viewportStartMs + visibleMs

        let rulerRect = CGRect(x: 0, y: 0, width: size.width, height: framesOriginY)
        ctx.fill(Path(rulerRect), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.85)))

        var ms = floor(viewportStartMs / minorInterval) * minorInterval
        while ms <= viewportEndMs + minorInterval {
            let xRatio = (ms - viewportStartMs) / visibleMs
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

        ms = floor(viewportStartMs / majorInterval) * majorInterval
        while ms <= viewportEndMs + majorInterval {
            let xRatio = (ms - viewportStartMs) / visibleMs
            let x = CGFloat(xRatio) * size.width
            if x >= 0, x <= size.width {
                ctx.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: x, y: framesOriginY - 8))
                        p.addLine(to: CGPoint(x: x, y: framesOriginY))
                    },
                    with: .color(.secondary), lineWidth: 1.0
                )
                ctx.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: x, y: framesOriginY))
                        p.addLine(to: CGPoint(x: x, y: size.height))
                    },
                    with: .color(.primary.opacity(0.06)), lineWidth: 0.5
                )
                let label = formatMs(ms, interval: majorInterval)
                let resolved = ctx.resolve(Text(label)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary))
                ctx.draw(resolved, at: CGPoint(x: x + 3, y: 3), anchor: .topLeading)
            }
            ms += majorInterval
        }

        ctx.stroke(
            Path { p in
                p.move(to: CGPoint(x: 0, y: framesOriginY))
                p.addLine(to: CGPoint(x: size.width, y: framesOriginY))
            },
            with: .color(.primary.opacity(0.18)), lineWidth: 0.5
        )

        if hoveredCellID != nil {
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
                y: pillRect.minY, width: pillRect.width, height: pillRect.height
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
        if interval >= 1000 { return String(format: "%.1fs", ms / 1000) }
        if interval >= 1 { return String(format: "%.0f ms", ms) }
        if interval >= 0.1 { return String(format: "%.1f ms", ms) }
        return String(format: "%.2f ms", ms)
    }

    private func color(for cell: FlameChartCell, isHovered: Bool, isSelected: Bool, dim: Bool) -> Color {
        let hash = cell.symbol.utf8.reduce(UInt32(2_166_136_261)) { acc, byte in
            (acc ^ UInt32(byte)) &* 16_777_619
        }
        let hueBand = Double(hash % 60) / 60.0
        let hue = 0.0 + hueBand * 0.12
        let sat = isSelected ? 0.95 : (isHovered ? 0.85 : 0.55)
        let bright = dim ? 0.55 : (isSelected ? 1.0 : (isHovered ? 1.0 : 0.95))
        return Color(hue: hue, saturation: sat, brightness: bright, opacity: dim ? 0.55 : 1.0)
    }

    private func truncatedSymbol(for cell: FlameChartCell, fittingWidth: CGFloat) -> String {
        let approxCharsPerPoint = 1.0 / 6.5
        let maxChars = max(2, Int(fittingWidth * approxCharsPerPoint))
        if cell.symbol.count <= maxChars { return cell.symbol }
        return String(cell.symbol.prefix(max(1, maxChars - 1))) + "…"
    }

    @ViewBuilder
    private func cursorGuide(at point: CGPoint, height: CGFloat) -> some View {
        if hoveredCellID != nil {
            Rectangle()
                .fill(Color.accentColor.opacity(0.45))
                .frame(width: 1, height: height - framesOriginY)
                .position(x: point.x, y: framesOriginY + (height - framesOriginY) / 2)
                .allowsHitTesting(false)
        }
    }

    // MARK: Hit-testing

    private func cellID(at point: CGPoint, in size: CGSize) -> UUID? {
        guard point.y >= framesOriginY else { return nil }
        let row = Int((point.y - framesOriginY) / Self.rowHeight)
        guard row >= 0, row <= thread.maxDepth else { return nil }
        let pointNs = nsAtPoint(point.x, in: size)
        for cell in thread.cells where cell.depth == row {
            if cell.startNs <= pointNs && pointNs < cell.endNs {
                return cell.id
            }
        }
        return nil
    }

    private func nsAtPoint(_ x: CGFloat, in size: CGSize) -> UInt64 {
        let span = viewportEndNs > viewportStartNs ? viewportEndNs - viewportStartNs : 1
        let frac = Swift.max(0.0, Swift.min(1.0, Double(x / size.width)))
        return viewportStartNs + UInt64(frac * Double(span))
    }

    // MARK: Wheel / pan / zoom

    private func handleWheel(event: NSEvent, locationInView: CGPoint, size: CGSize) {
        let dy = abs(event.scrollingDeltaY) > 0 ? event.scrollingDeltaY : event.deltaY
        let dx = abs(event.scrollingDeltaX) > 0 ? event.scrollingDeltaX : event.deltaX

        if event.modifierFlags.contains(.shift) || abs(dx) > abs(dy) {
            let span = Double(viewportEndNs > viewportStartNs ? viewportEndNs - viewportStartNs : 1)
            let panNs = Double(dx / size.width) * span
            pan(byNs: Int64(-panNs), startMin: viewportStartNs, startMax: viewportEndNs)
            return
        }

        let factor = pow(1.10, -dy / 20.0)
        let centerNs = nsAtPoint(locationInView.x, in: size)
        applyZoom(factor: factor, aroundNs: centerNs)
    }

    private func pan(byNs delta: Int64, startMin: UInt64, startMax: UInt64) {
        let traceStart = thread.startNs
        let traceEnd = thread.endNs
        let span = startMax - startMin
        var newMin: Int64 = Int64(startMin) + delta
        var newMax: Int64 = Int64(startMax) + delta
        if newMin < Int64(traceStart) {
            let overshoot = Int64(traceStart) - newMin
            newMin += overshoot
            newMax += overshoot
        }
        if newMax > Int64(traceEnd) {
            let overshoot = newMax - Int64(traceEnd)
            newMin -= overshoot
            newMax -= overshoot
        }
        viewportStartNs = UInt64(max(Int64(traceStart), newMin))
        viewportEndNs = UInt64(min(Int64(traceEnd), max(Int64(viewportStartNs) + 1, newMax)))
        _ = span   // silence warning if unused
    }

    private func applyZoom(factor: Double, aroundNs center: UInt64) {
        let traceStart = thread.startNs
        let traceEnd = thread.endNs
        let span = Double(viewportEndNs - viewportStartNs)
        let newSpan = Swift.max(1000.0, Swift.min(Double(traceEnd - traceStart), span * factor))
        let leftFraction = Double(center - viewportStartNs) / Swift.max(1.0, span)
        var newMin = Double(center) - leftFraction * newSpan
        var newMax = newMin + newSpan
        if newMin < Double(traceStart) {
            newMax += Double(traceStart) - newMin
            newMin = Double(traceStart)
        }
        if newMax > Double(traceEnd) {
            newMin -= newMax - Double(traceEnd)
            newMax = Double(traceEnd)
        }
        viewportStartNs = UInt64(Swift.max(Double(traceStart), newMin))
        viewportEndNs = UInt64(Swift.min(Double(traceEnd), Swift.max(Double(viewportStartNs) + 1, newMax)))
    }

    // MARK: Tooltip

    @ViewBuilder
    private func tooltip(for cell: FlameChartCell) -> some View {
        let durationMs = Double(cell.durationNs) / 1_000_000.0
        VStack(alignment: .leading, spacing: 2) {
            Text(cell.symbol)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .lineLimit(3)
            HStack(spacing: 6) {
                Text(String(format: "%.3f ms", durationMs))
                if let module = cell.module {
                    Text("·")
                    Text(module).foregroundStyle(.tertiary)
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(radius: 4, y: 2)
        .frame(maxWidth: 380, alignment: .leading)
    }

    private func tooltipPosition(at point: CGPoint, in size: CGSize) -> CGPoint {
        let estimatedWidth: CGFloat = 240
        let estimatedHeight: CGFloat = 48
        var x = point.x + 14 + estimatedWidth / 2
        var y = point.y + 14 + estimatedHeight / 2
        if x + estimatedWidth / 2 > size.width { x = point.x - 14 - estimatedWidth / 2 }
        if y + estimatedHeight / 2 > size.height { y = point.y - 14 - estimatedHeight / 2 }
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Wheel-event bridge (same pattern as FlamegraphView)

private struct WheelEventBridge: NSViewRepresentable {
    let onWheel: (NSEvent, CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

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
                guard let self,
                      let view = self.trackedView,
                      let window = view.window,
                      event.window == window else { return event }
                let local = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(local) else { return event }
                self.onWheel?(event, local)
                return nil
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }

        deinit { removeMonitor() }
    }
}

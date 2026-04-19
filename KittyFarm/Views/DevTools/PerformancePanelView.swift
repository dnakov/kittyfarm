import AppKit
import Charts
import SwiftUI

struct PerformancePanelView: View {
    @Bindable var store: KittyFarmStore

    var body: some View {
        if let focused = store.focusedIOSDevice {
            PerformancePanelContent(store: store, state: focused)
        } else if store.activeDevices.contains(where: { $0.descriptor.platform == .androidEmulator }) {
            DevToolsAndroidStubView(feature: "CPU")
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "speedometer")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text("No active device")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct PerformancePanelContent: View {
    @Bindable var store: KittyFarmStore
    @Bindable var state: DeviceState

    @State private var sampleState: DeepSampleState = .idle
    @State private var rawSampleText: String = ""
    @State private var parsedTree: [SampleTreeNode] = []
    @State private var flameThreads: [FlamegraphThread] = []
    @State private var flameChartTrace: TimeProfileTrace?
    @State private var flameChartThreads: [FlameChartThread] = []
    @State private var sampleError: String?
    @State private var sampleDurationSec: Int = 10
    @State private var resultViewMode: ResultViewMode = .flame
    @State private var activeRecording: CPUMonitor.DeepSampleRecording?
    @State private var activeXctraceSession: XctraceRecorder.Session?
    @State private var recordingElapsed: TimeInterval = 0
    @State private var elapsedTimer: Timer?
    @State private var recordingBackend: RecordingBackend = .sample

    private enum DeepSampleState: Equatable {
        case idle
        case sampling          // fixed-duration capture in flight
        case recording         // open-ended recording in flight (sample backend)
        case xctracing         // open-ended recording in flight (xctrace backend)
        case stoppingXctrace   // SIGINT sent, waiting for xctrace to flush its bundle
        case parsingXctrace    // bundle written, running xctrace export + XML parse
        case captured
    }

    private enum ResultViewMode: String, CaseIterable, Identifiable {
        case flame
        case tree
        case chart
        var id: String { rawValue }
        var label: String {
            switch self {
            case .flame: return "Flamegraph"
            case .tree:  return "Tree"
            case .chart: return "Timeline"
            }
        }
    }

    private enum RecordingBackend: String, CaseIterable, Identifiable {
        case sample           // /usr/bin/sample — fast, aggregated
        case xctrace          // xctrace + Time Profiler — symbolicated timeline
        var id: String { rawValue }
        var label: String {
            switch self {
            case .sample:  return "Quick (sample)"
            case .xctrace: return "Detailed (xctrace)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.currentPID == nil {
                emptyPIDState
            } else {
                chart
                summary
                Divider()
                deepSampleSection
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyPIDState: some View {
        VStack(spacing: 6) {
            Image(systemName: "speedometer")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text("App not running")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Run Build & Play to attach.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chart: some View {
        let cutoff = Date().addingTimeInterval(-120)
        let samples = state.cpuSamples.filter { $0.timestamp >= cutoff }
        let peak = samples.map(\.cpuPercent).max() ?? 0
        let yMax = max(peak * 1.2, 10)

        return Group {
            if samples.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Sampling…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                Chart(samples) { sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("CPU %", sample.cpuPercent)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.orange)
                }
                .chartYScale(domain: 0...yMax)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.minute().second())
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let pct = value.as(Double.self) {
                                Text("\(Int(pct))%")
                            }
                        }
                    }
                }
                .frame(minHeight: 120)
            }
        }
    }

    private var summary: some View {
        let samples = state.cpuSamples
        let current = samples.last?.cpuPercent
        let peak = samples.map(\.cpuPercent).max()
        let threads = state.latestThreadCount

        return HStack(spacing: 24) {
            labeledValue("Current", value: current.map(formatPercent) ?? "—")
            labeledValue("Peak", value: peak.map(formatPercent) ?? "—")
            if let threads {
                labeledValue("Threads", value: "\(threads)")
            }
            Spacer()
        }
    }

    private func labeledValue(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
        }
    }

    @ViewBuilder
    private var deepSampleSection: some View {
        switch sampleState {
        case .idle:
            idleSampleControls
        case .sampling:
            samplingProgress
        case .recording, .xctracing:
            recordingControls
        case .stoppingXctrace:
            postRecordProgress(label: "Stopping xctrace and flushing trace bundle…")
        case .parsingXctrace:
            postRecordProgress(label: "Exporting and parsing trace…")
        case .captured:
            capturedTree
        }
    }

    private func postRecordProgress(label: String) -> some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("(can take a while for long recordings)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private var idleSampleControls: some View {
        let isIOSSim = state.descriptor.platform == .iOSSimulator
        // xctrace `--device <UDID> --attach <pid>` records but its SIGINT flush
        // hangs for minutes against iOS simulator processes, then writes an empty
        // bundle. Disable that combination until Apple fixes it.
        let xctraceUsable = !isIOSSim

        return HStack(spacing: 8) {
            Button {
                switch recordingBackend {
                case .sample:  beginDeepRecording()
                case .xctrace: beginXctraceRecording()
                }
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(state.currentPID == nil || (recordingBackend == .xctrace && !xctraceUsable))
            .help("Start an open-ended recording. Click Stop when you're done.")

            Picker("Backend", selection: $recordingBackend) {
                ForEach(RecordingBackend.allCases) { backend in
                    if backend == .xctrace && !xctraceUsable {
                        Text("\(backend.label) — broken for iOS sim").tag(backend)
                    } else {
                        Text(backend.label).tag(backend)
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 240)
            .help("Quick = aggregated flamegraph, no time axis. Detailed = real timeline via xctrace; currently hangs on iOS simulator processes (Apple bug — works for native macOS targets only).")
            .onChange(of: recordingBackend) { _, new in
                if new == .xctrace && !xctraceUsable { recordingBackend = .sample }
            }

            Divider().frame(height: 16)

            Button("Quick \(sampleDurationSec)s sample") { beginDeepSample() }
                .disabled(state.currentPID == nil)
                .help("Fixed-duration sample (aggregated only).")
            Picker("Duration", selection: $sampleDurationSec) {
                Text("5s").tag(5)
                Text("10s").tag(10)
                Text("20s").tag(20)
                Text("30s").tag(30)
                Text("60s").tag(60)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 80)

            if let error = sampleError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
        }
    }

    private var samplingProgress: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Sampling…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var recordingControls: some View {
        HStack(spacing: 8) {
            Button {
                if sampleState == .xctracing { stopXctraceRecording() }
                else { stopDeepRecording() }
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(".", modifiers: [.command])

            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .opacity(0.6)
                .scaleEffect(1.0 + 0.2 * sin(recordingElapsed * 3))
                .animation(.easeInOut(duration: 0.2), value: recordingElapsed)

            Text("Recording \(formatElapsed(recordingElapsed)) · \(sampleState == .xctracing ? "xctrace" : "sample")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button("Cancel") {
                if sampleState == .xctracing { cancelXctraceRecording() }
                else { cancelDeepRecording() }
            }
            .controlSize(.small)

            Spacer()
        }
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private var capturedTree: some View {
        let availableModes: [ResultViewMode] = flameChartTrace != nil ? [.chart, .flame, .tree] : [.flame, .tree]

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Call graph")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("View", selection: $resultViewMode) {
                    ForEach(availableModes) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)

                Spacer()
                if flameChartTrace == nil {
                    Button("Copy raw") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(rawSampleText, forType: .string)
                    }
                    .disabled(rawSampleText.isEmpty)
                }
                Button("New sample") {
                    sampleState = .idle
                    parsedTree = []
                    flameThreads = []
                    flameChartTrace = nil
                    flameChartThreads = []
                    rawSampleText = ""
                }
            }

            switch resultViewMode {
            case .chart:
                if let trace = flameChartTrace, !flameChartThreads.isEmpty {
                    ScrollView([.vertical]) {
                        FlameChartView(
                            threads: flameChartThreads,
                            traceStartNs: trace.startNs,
                            traceEndNs: trace.endNs
                        )
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(minHeight: 220)
                } else {
                    Text("Timeline only available for xctrace recordings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .flame:
                if !flameThreads.isEmpty {
                    ScrollView([.vertical]) {
                        FlamegraphView(threads: flameThreads)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(minHeight: 220)
                } else if !flameChartThreads.isEmpty {
                    Text("Aggregated flamegraph not available for xctrace recordings yet.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No call-graph data parsed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .tree:
                if !parsedTree.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(parsedTree) { thread in
                                SampleTreeNodeView(node: thread, depth: 0)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 220)
                } else {
                    Text("Tree view requires the sample backend.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            // If we landed in chart mode but only have aggregated data, fall back.
            if resultViewMode == .chart && flameChartTrace == nil { resultViewMode = .flame }
        }
    }

    private func beginDeepSample() {
        guard let pid = state.currentPID else { return }
        sampleError = nil
        sampleState = .sampling
        let duration = sampleDurationSec

        Task {
            do {
                let text = try await store.captureDeepSample(pid: pid, durationSec: duration)
                presentCapturedSample(text: text)
            } catch {
                sampleError = error.localizedDescription
                sampleState = .idle
            }
        }
    }

    private func beginDeepRecording() {
        guard let pid = state.currentPID else { return }
        sampleError = nil
        sampleState = .recording
        recordingElapsed = 0

        Task {
            do {
                let recording = try await store.startDeepSampleRecording(pid: pid)
                await MainActor.run {
                    activeRecording = recording
                    startElapsedTimer()
                }
            } catch {
                await MainActor.run {
                    sampleError = error.localizedDescription
                    sampleState = .idle
                }
            }
        }
    }

    private func stopDeepRecording() {
        guard let recording = activeRecording else { return }
        stopElapsedTimer()
        sampleState = .sampling   // reuse the in-flight indicator while sample flushes its report

        Task {
            do {
                let text = try await store.stopDeepSampleRecording(recording)
                await MainActor.run {
                    activeRecording = nil
                    presentCapturedSample(text: text)
                }
            } catch {
                await MainActor.run {
                    sampleError = error.localizedDescription
                    activeRecording = nil
                    sampleState = .idle
                }
            }
        }
    }

    private func cancelDeepRecording() {
        guard let recording = activeRecording else { return }
        stopElapsedTimer()
        Task {
            await store.cancelDeepSampleRecording(recording)
            await MainActor.run {
                activeRecording = nil
                sampleState = .idle
            }
        }
    }

    private func presentCapturedSample(text: String) {
        rawSampleText = text
        let tree = SampleParser.parse(text)
        parsedTree = tree
        flameThreads = FlamegraphLayout.build(from: tree)
        flameChartTrace = nil
        flameChartThreads = []
        if resultViewMode == .chart { resultViewMode = .flame }
        sampleState = .captured
    }

    private func beginXctraceRecording() {
        guard let pid = state.currentPID else { return }
        sampleError = nil
        sampleState = .xctracing
        recordingElapsed = 0
        let simulatorUDID = state.descriptor.iosUDID

        Task {
            do {
                let session = try await store.startXctraceRecording(pid: pid, simulatorUDID: simulatorUDID)
                await MainActor.run {
                    activeXctraceSession = session
                    startElapsedTimer()
                }
            } catch {
                await MainActor.run {
                    sampleError = error.localizedDescription
                    sampleState = .idle
                }
            }
        }
    }

    private func stopXctraceRecording() {
        guard let session = activeXctraceSession else { return }
        stopElapsedTimer()
        sampleState = .stoppingXctrace

        Task {
            do {
                // The store call wraps two heavy steps: SIGINT-and-wait (xctrace
                // flush), then `xctrace export` + XML parse. Update the UI
                // between them so the user sees progress.
                let trace = try await store.stopXctraceRecording(session) {
                    Task { @MainActor in
                        sampleState = .parsingXctrace
                    }
                }
                let chartThreads = FlameChartLayout.build(from: trace)
                await MainActor.run {
                    activeXctraceSession = nil
                    flameChartTrace = trace
                    flameChartThreads = chartThreads
                    rawSampleText = ""
                    parsedTree = []
                    flameThreads = []
                    resultViewMode = .chart
                    sampleState = .captured
                }
            } catch {
                await MainActor.run {
                    sampleError = error.localizedDescription
                    activeXctraceSession = nil
                    sampleState = .idle
                }
            }
        }
    }

    private func cancelXctraceRecording() {
        guard let session = activeXctraceSession else { return }
        stopElapsedTimer()
        Task {
            await store.cancelXctraceRecording(session)
            await MainActor.run {
                activeXctraceSession = nil
                sampleState = .idle
            }
        }
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        let start = Date()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            Task { @MainActor in
                recordingElapsed = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }
}

private struct SampleTreeNodeView: View {
    let node: SampleTreeNode
    let depth: Int

    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: node.children.isEmpty ? "circle.fill" : (isExpanded ? "chevron.down" : "chevron.right"))
                        .font(.system(size: node.children.isEmpty ? 4 : 9))
                        .foregroundStyle(node.children.isEmpty ? Color.secondary : Color.primary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .disabled(node.children.isEmpty)

                Text("\(node.sampleCount)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 40, alignment: .trailing)

                Text(node.symbol)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)

                if let module = node.module {
                    Text("(\(module))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 14)
            .contentShape(Rectangle())
            .onTapGesture {
                if !node.children.isEmpty {
                    isExpanded.toggle()
                }
            }

            if isExpanded {
                ForEach(node.children) { child in
                    SampleTreeNodeView(node: child, depth: depth + 1)
                }
            }
        }
    }
}

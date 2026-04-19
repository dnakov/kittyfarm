import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct MemoryPanelView: View {
    @Bindable var store: KittyFarmStore

    var body: some View {
        if let focused = store.focusedIOSDevice {
            MemoryPanelContent(store: store, state: focused)
        } else if store.activeDevices.contains(where: { $0.descriptor.platform == .androidEmulator }) {
            DevToolsAndroidStubView(feature: "memory")
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "memorychip")
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

private struct MemoryPanelContent: View {
    @Bindable var store: KittyFarmStore
    @Bindable var state: DeviceState

    @State private var activeSheet: SnapshotKind?
    @State private var snapshotText: String = ""
    @State private var snapshotError: String?
    @State private var isLoadingSnapshot = false

    private enum SnapshotKind: String, Identifiable {
        case heap, vmmap, leaks
        var id: String { rawValue }
        var title: String {
            switch self {
            case .heap: return "Heap Snapshot"
            case .vmmap: return "VM Map"
            case .leaks: return "Leaks"
            }
        }
        var fileExtension: String { "txt" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.currentPID == nil {
                emptyPIDState
            } else {
                chart
                summary
                snapshotButtons
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $activeSheet, onDismiss: clearSheet) { kind in
            snapshotSheet(kind: kind)
        }
    }

    private var emptyPIDState: some View {
        VStack(spacing: 6) {
            Image(systemName: "memorychip")
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
        let samples = state.memorySamples.filter { $0.timestamp >= cutoff }
        let peak = samples.map(\.footprintMB).max() ?? 1
        let yMax = max(peak * 1.2, 1)

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
                        y: .value("MB", sample.footprintMB)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.blue)
                }
                .chartYScale(domain: 0...yMax)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.minute().second())
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .frame(minHeight: 120)
            }
        }
    }

    private var summary: some View {
        let samples = state.memorySamples
        let current = samples.last?.footprintMB
        let peak = samples.map(\.footprintMB).max()

        return HStack(spacing: 24) {
            labeledValue("Current", value: current.map(formatMB) ?? "—")
            labeledValue("Peak", value: peak.map(formatMB) ?? "—")
            if let resident = samples.last?.residentMB, resident > 0 {
                labeledValue("Resident", value: formatMB(resident))
            }
            if let dirty = samples.last?.dirtyMB, dirty > 0 {
                labeledValue("Dirty", value: formatMB(dirty))
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

    private var snapshotButtons: some View {
        HStack(spacing: 8) {
            Button("Heap snapshot") { openSheet(.heap) }
            Button("VM map") { openSheet(.vmmap) }
            Button("Leaks") { openSheet(.leaks) }
            Spacer()
        }
        .disabled(state.currentPID == nil)
    }

    private func snapshotSheet(kind: SnapshotKind) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(kind.title)
                    .font(.headline)
                Spacer()
                Button("Close") { activeSheet = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            if isLoadingSnapshot {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Capturing \(kind.title.lowercased())…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = snapshotError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(snapshotText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }

            Divider()

            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snapshotText, forType: .string)
                }
                .disabled(snapshotText.isEmpty)

                Button("Save…") { saveSnapshot(kind: kind) }
                    .disabled(snapshotText.isEmpty)
                Spacer()
            }
            .padding()
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private func openSheet(_ kind: SnapshotKind) {
        guard let pid = state.currentPID else { return }
        activeSheet = kind
        snapshotText = ""
        snapshotError = nil
        isLoadingSnapshot = true

        Task {
            do {
                let text: String
                switch kind {
                case .heap:
                    text = try await store.captureHeapSnapshot(pid: pid)
                case .vmmap:
                    text = try await store.captureVMMapSnapshot(pid: pid)
                case .leaks:
                    text = try await store.captureLeaksSnapshot(pid: pid)
                }
                snapshotText = text
            } catch {
                snapshotError = error.localizedDescription
            }
            isLoadingSnapshot = false
        }
    }

    private func clearSheet() {
        snapshotText = ""
        snapshotError = nil
        isLoadingSnapshot = false
    }

    private func saveSnapshot(kind: SnapshotKind) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(kind.rawValue)-\(Int(Date().timeIntervalSince1970)).\(kind.fileExtension)"
        if panel.runModal() == .OK, let url = panel.url {
            try? snapshotText.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func formatMB(_ value: Double) -> String {
        String(format: "%.1f MB", value)
    }
}

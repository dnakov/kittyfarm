import SwiftUI

struct BuildLogPanelView: View {
    @Bindable var store: KittyFarmStore
    @State private var searchText = ""
    @State private var severityFilter = SeverityFilter.all
    @State private var autoScroll = true

    private enum SeverityFilter: String, CaseIterable {
        case all = "All"
        case issues = "Issues"
        case errors = "Errors"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var displayedLogs: [BuildLogEntry] {
        var logs = store.filteredBuildLogs

        switch severityFilter {
        case .all: break
        case .issues: logs = logs.filter { $0.severity != .info }
        case .errors: logs = logs.filter { $0.severity == .error }
        }

        if !searchText.isEmpty {
            logs = logs.filter { $0.message.localizedCaseInsensitiveContains(searchText) }
        }

        return logs
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if store.availableBuildLogFilters.count > 1 {
                scopeBar
                Divider()
            }

            logList
        }
        .frame(minHeight: 180, idealHeight: 220, maxHeight: .infinity)
        .background(.ultraThickMaterial)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("Build Log")
                .font(.subheadline.weight(.semibold))

            if store.isRunningBuildAndPlay {
                ProgressView()
                    .controlSize(.small)
            }

            countBadge(store.buildWarningCount, icon: "exclamationmark.triangle.fill", color: .yellow)
            countBadge(store.buildErrorCount, icon: "xmark.circle.fill", color: .red)

            Spacer()

            Picker("", selection: $severityFilter) {
                ForEach(SeverityFilter.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)

            TextField("Filter", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)

            Button {
                autoScroll.toggle()
            } label: {
                Image(systemName: "arrow.down.to.line.compact")
                    .foregroundStyle(autoScroll ? Color.accentColor : .secondary)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help(autoScroll ? "Auto-scroll enabled" : "Auto-scroll disabled")

            Button("Clear") { store.clearBuildLogs() }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(store.buildLogs.isEmpty)

            Button { store.toggleBuildLogs() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Scope Bar

    private var scopeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.availableBuildLogFilters) { filter in
                    filterChip(filter)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .background(.bar)
    }

    // MARK: - Log List

    private var logList: some View {
        let logs = displayedLogs
        return LogTextView(entries: logs, autoScroll: autoScroll, timeFormatter: Self.timeFormatter) { entry in
            sourceLabel(for: entry.source)
        } sourceColor: { entry in
            sourceColor(for: entry.source)
        } messageColor: { entry in
            messageColor(for: entry)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func countBadge(_ count: Int, icon: String, color: Color) -> some View {
        Label("\(count)", systemImage: icon)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(count > 0 ? color : .secondary)
    }

    private func filterChip(_ filter: BuildLogFilter) -> some View {
        let isSelected = store.selectedBuildLogFilterID == filter.id
        return Button { store.selectBuildLogFilter(filter) } label: {
            Text(filter.title)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .glassEffect(isSelected ? .regular.tint(.accentColor) : .regular, in: .capsule)
        .fixedSize()
    }

    private func rowBackground(for entry: BuildLogEntry) -> Color {
        switch entry.severity {
        case .error: Color.red.opacity(0.08)
        case .warning: Color.yellow.opacity(0.04)
        case .info: .clear
        }
    }

    private func sourceLabel(for source: BuildLogSource) -> String {
        switch source {
        case .command: "cmd"
        case .stdout: "out"
        case .stderr: "err"
        case .system: "sys"
        }
    }

    private func sourceColor(for source: BuildLogSource) -> Color {
        switch source {
        case .command: .blue
        case .stdout: .secondary
        case .stderr: .orange
        case .system: .purple
        }
    }

    private func messageColor(for entry: BuildLogEntry) -> Color {
        switch entry.severity {
        case .error: .red
        case .warning: .yellow
        case .info:
            switch entry.source {
            case .command: .blue
            case .system: .secondary
            case .stdout, .stderr: .primary
            }
        }
    }
}

private struct LogTextView: NSViewRepresentable {
    let entries: [BuildLogEntry]
    let autoScroll: Bool
    let timeFormatter: DateFormatter
    let sourceLabel: (BuildLogEntry) -> String
    let sourceColor: (BuildLogEntry) -> Color
    let messageColor: (BuildLogEntry) -> Color

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        let previousCount = context.coordinator.lastEntryCount
        let newCount = entries.count

        if newCount == 0 {
            textView.textStorage?.setAttributedString(NSAttributedString())
            context.coordinator.lastEntryCount = 0
            return
        }

        if newCount < previousCount {
            textView.textStorage?.setAttributedString(buildAttributedString(from: entries))
        } else if newCount > previousCount {
            let newEntries = Array(entries[previousCount...])
            let appended = buildAttributedString(from: newEntries, startWithNewline: previousCount > 0)
            textView.textStorage?.append(appended)
        }

        context.coordinator.lastEntryCount = newCount

        if autoScroll {
            textView.scrollToEndOfDocument(nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var textView: NSTextView?
        var lastEntryCount = 0
    }

    private func buildAttributedString(from entries: [BuildLogEntry], startWithNewline: Bool = false) -> NSMutableAttributedString {
        let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let result = NSMutableAttributedString()

        for (index, entry) in entries.enumerated() {
            if startWithNewline || index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }

            let time = NSAttributedString(
                string: timeFormatter.string(from: entry.timestamp) + " ",
                attributes: [.foregroundColor: NSColor.gray, .font: monoFont]
            )
            result.append(time)

            let source = NSAttributedString(
                string: sourceLabel(entry) + " ",
                attributes: [.foregroundColor: NSColor(sourceColor(entry)), .font: monoFont]
            )
            result.append(source)

            var msgAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor(messageColor(entry)),
                .font: monoFont
            ]
            if entry.severity == .error {
                msgAttrs[.backgroundColor] = NSColor.red.withAlphaComponent(0.08)
            } else if entry.severity == .warning {
                msgAttrs[.backgroundColor] = NSColor.yellow.withAlphaComponent(0.04)
            }

            result.append(NSAttributedString(string: entry.message, attributes: msgAttrs))
        }

        return result
    }
}

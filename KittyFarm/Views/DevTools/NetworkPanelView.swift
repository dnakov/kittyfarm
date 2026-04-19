import AppKit
import SwiftUI

struct NetworkPanelView: View {
    @Bindable var store: KittyFarmStore
    @State private var selectedRequestID: NetworkRequest.ID?
    @State private var searchText: String = ""

    var body: some View {
        if let device = store.focusedIOSDevice {
            content(for: device)
        } else if store.activeDevices.contains(where: { $0.descriptor.platform == .androidEmulator }) {
            DevToolsAndroidStubView(feature: "network")
        } else {
            emptyState(text: "Connect an iOS simulator to inspect network traffic.")
        }
    }

    @ViewBuilder
    private func content(for device: DeviceState) -> some View {
        VStack(spacing: 0) {
            header(for: device)
            if let error = device.networkError, isMitmproxyMissingError(error) {
                mitmproxyMissingBanner
            } else if let error = device.networkError {
                errorBanner(error)
            } else if !device.networkEnabled {
                hintBanner("Configuring proxy and installing trust certificate…")
            } else if device.networkRequests.isEmpty {
                hintBanner("Proxy listening on 127.0.0.1. If no requests show, the simulator may not be routing through it — see the README on enabling the Mac system proxy. TLS-pinned apps won't appear either.")
            }

            Divider()

            if filteredRequests(for: device).isEmpty && device.networkError == nil {
                emptyState(text: device.networkEnabled
                    ? "No network activity yet."
                    : "Waiting for mitmdump to start…")
            } else {
                HSplitView {
                    requestList(for: device)
                        .frame(minWidth: 300, idealWidth: 480)
                    detailPane(for: device)
                        .frame(minWidth: 340)
                }
            }
        }
    }

    // MARK: - Header

    private func header(for device: DeviceState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .foregroundStyle(.secondary)
            Text("\(device.networkRequests.count) request\(device.networkRequests.count == 1 ? "" : "s")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            TextField("Filter by URL", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)

            Spacer()

            Button {
                store.clearNetworkRequests()
                selectedRequestID = nil
            } label: {
                Label("Clear", systemImage: "trash")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(device.networkRequests.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Banners

    private var mitmproxyMissingBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("mitmproxy not installed")
                    .font(.caption.weight(.semibold))
                Text("Run `brew install mitmproxy`, then reconnect the device.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString("brew install mitmproxy", forType: .string)
            } label: {
                Label("Copy Command", systemImage: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.red.opacity(0.1))
    }

    private func hintBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.blue)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.blue.opacity(0.08))
    }

    private func isMitmproxyMissingError(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("mitmproxy is not installed")
            || text.localizedCaseInsensitiveContains("brew install mitmproxy")
    }

    // MARK: - Request list

    private func filteredRequests(for device: DeviceState) -> [NetworkRequest] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = device.networkRequests
        guard !trimmed.isEmpty else { return base }
        return base.filter { $0.url.localizedCaseInsensitiveContains(trimmed) }
    }

    private func requestList(for device: DeviceState) -> some View {
        let items = filteredRequests(for: device)
        return Table(items, selection: $selectedRequestID) {
            TableColumn("") { request in
                Text(request.method)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .width(50)

            TableColumn("URL") { request in
                Text(request.url)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(request.url)
            }

            TableColumn("Status") { request in
                statusLabel(for: request)
            }
            .width(60)

            TableColumn("Size") { request in
                Text(Self.formatBytes(request.bytesReceived))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(80)

            TableColumn("Time") { request in
                if let ms = request.durationMs {
                    Text(String(format: "%.0f ms", ms))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .width(70)
        }
    }

    @ViewBuilder
    private func statusLabel(for request: NetworkRequest) -> some View {
        if let status = request.status {
            Text("\(status)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(Self.color(forStatus: status))
        } else if request.error != nil {
            Text("ERR")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.red)
        } else {
            Text("—")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private func detailPane(for device: DeviceState) -> some View {
        if let id = selectedRequestID,
           let request = device.networkRequests.first(where: { $0.id == id }) {
            RequestDetailView(request: request)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "hand.point.left")
                    .foregroundStyle(.tertiary)
                Text("Select a request")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Helpers

    private func emptyState(text: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "network")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Apps that pin TLS won't appear here.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    static func color(forStatus status: Int) -> Color {
        switch status {
        case 200..<300: return .green
        case 300..<400: return .yellow
        case 400..<600: return .red
        default: return .secondary
        }
    }

    static func formatBytes(_ bytes: Int) -> String {
        guard bytes > 0 else { return "—" }
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        return String(format: "%.1f MB", mb)
    }
}

// MARK: - Request detail

private struct RequestDetailView: View {
    let request: NetworkRequest
    @State private var selectedTab: Tab = .headers

    enum Tab: String, CaseIterable, Identifiable {
        case headers = "Headers"
        case request = "Request"
        case response = "Response"
        case timing = "Timing"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()

            switch selectedTab {
            case .headers:
                HeadersTab(request: request)
            case .request:
                RequestTab(request: request)
            case .response:
                ResponseTab(request: request)
            case .timing:
                TimingTab(request: request)
            }
        }
    }
}

private struct HeadersTab: View {
    let request: NetworkRequest

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Request Headers")
                if request.requestHeaders.isEmpty {
                    Text("None").font(.caption).foregroundStyle(.tertiary)
                } else {
                    headersList(request.requestHeaders)
                }
                Divider()
                sectionHeader("Response Headers")
                if request.responseHeaders.isEmpty {
                    Text("None").font(.caption).foregroundStyle(.tertiary)
                } else {
                    headersList(request.responseHeaders)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func headersList(_ pairs: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(pair.0)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(pair.1)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
        }
    }
}

private struct RequestTab: View {
    let request: NetworkRequest

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(request.method)
                        .font(.caption.monospaced().weight(.semibold))
                    Text(request.url)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .truncationMode(.middle)
                }

                Button {
                    let curl = Self.buildCurl(request)
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(curl, forType: .string)
                } label: {
                    Label("Copy as cURL", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Divider()

                Text("Body")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                BodyView(
                    data: request.requestBody,
                    truncated: request.requestBodyTruncated,
                    contentType: Self.contentType(request.requestHeaders)
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    static func contentType(_ headers: [(String, String)]) -> String? {
        headers.first { $0.0.lowercased() == "content-type" }?.1
    }

    static func buildCurl(_ request: NetworkRequest) -> String {
        var parts: [String] = ["curl"]
        parts.append("-X \(shellEscape(request.method))")
        for (key, value) in request.requestHeaders where key.lowercased() != "content-length" {
            parts.append("-H \(shellEscape("\(key): \(value)"))")
        }
        if let body = request.requestBody,
           let string = String(data: body, encoding: .utf8), !string.isEmpty {
            parts.append("--data-raw \(shellEscape(string))")
        }
        parts.append(shellEscape(request.url))
        return parts.joined(separator: " ")
    }

    static func shellEscape(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct ResponseTab: View {
    let request: NetworkRequest

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if let status = request.status {
                        Text("Status")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("\(status)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(NetworkPanelView.color(forStatus: status))
                    }
                    if let error = request.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Divider()

                Text("Body")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                BodyView(
                    data: request.responseBody,
                    truncated: request.responseBodyTruncated,
                    contentType: RequestTab.contentType(request.responseHeaders)
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }
}

private struct TimingTab: View {
    let request: NetworkRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Started at", Self.formatter.string(from: request.startedAt))
            row("Duration", request.durationMs.map { String(format: "%.1f ms", $0) } ?? "—")
            row("Bytes sent", NetworkPanelView.formatBytes(request.bytesSent))
            row("Bytes received", NetworkPanelView.formatBytes(request.bytesReceived))
            if let port = request.clientPort {
                row("Client port", "\(port)")
            }
            if let pid = request.sourcePID {
                row("Source PID", "\(pid)")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.caption.monospacedDigit())
                .textSelection(.enabled)
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()
}

private struct BodyView: View {
    let data: Data?
    let truncated: Bool
    let contentType: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let data, !data.isEmpty {
                if truncated {
                    Text("Body truncated at 256 KB")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let text = prettifiedText(data: data) {
                    ScrollView([.vertical, .horizontal]) {
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 140, idealHeight: 220)
                } else {
                    HexDumpView(data: data, byteLimit: 4096)
                        .frame(minHeight: 140, idealHeight: 220)
                }
            } else {
                Text("No body")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func prettifiedText(data: Data) -> String? {
        let type = contentType?.lowercased() ?? ""
        let isTextish = type.contains("json")
            || type.contains("text/")
            || type.contains("xml")
            || type.contains("javascript")
            || type.contains("form-urlencoded")
            || type.isEmpty

        if type.contains("json") {
            if let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: pretty, encoding: .utf8) {
                return text
            }
        }

        guard isTextish else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}

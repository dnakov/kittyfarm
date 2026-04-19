import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct StoragePanelView: View {
    @Bindable var store: KittyFarmStore
    @State private var selection: StorageNode?

    var body: some View {
        if let device = store.focusedIOSDevice {
            content(device: device)
        } else if store.activeDevices.contains(where: { $0.descriptor.platform == .androidEmulator }) {
            DevToolsAndroidStubView(feature: "storage")
        } else {
            emptyState(message: "Connect an iOS simulator to inspect its sandbox.")
        }
    }

    @ViewBuilder
    private func content(device: DeviceState) -> some View {
        VStack(spacing: 0) {
            toolbar(device: device)
            Divider()
            if let snapshot = device.storageSnapshot {
                HSplitView {
                    treeAndDefaults(snapshot: snapshot)
                        .frame(minWidth: 220, idealWidth: 320)
                    detailPane
                        .frame(minWidth: 260)
                }
            } else {
                emptyState(message: device.isRefreshingStorage ? "Refreshing…" : "Click Refresh to load the sandbox.")
            }
        }
    }

    @ViewBuilder
    private func toolbar(device: DeviceState) -> some View {
        HStack(spacing: 8) {
            Button {
                Task { await store.refreshStorage(for: device) }
            } label: {
                HStack(spacing: 4) {
                    if device.isRefreshingStorage {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Refresh")
                }
            }
            .disabled(device.isRefreshingStorage || store.selectedIOSProject?.bundleIdentifier == nil)

            Button {
                if let path = device.storageSnapshot?.rootPath {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text("Reveal in Finder")
                }
            }
            .disabled(device.storageSnapshot == nil)

            Spacer()

            if let snapshot = device.storageSnapshot {
                Text(snapshot.rootPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(snapshot.rootPath)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func treeAndDefaults(snapshot: StorageSnapshot) -> some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Files") {
                    OutlineGroup(snapshot.root.children ?? [], id: \.self, children: \.children) { node in
                        nodeRow(node)
                            .tag(Optional(node))
                    }
                }

                DisclosureGroup("UserDefaults (\(snapshot.userDefaults.count))") {
                    if snapshot.userDefaults.isEmpty {
                        Text("No values")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(snapshot.userDefaults.keys.sorted(), id: \.self) { key in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(key)
                                    .font(.caption.weight(.medium))
                                Text(snapshot.userDefaults[key] ?? "")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private func nodeRow(_ node: StorageNode) -> some View {
        HStack(spacing: 4) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(node.isDirectory ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            Text(node.name)
                .lineLimit(1)
            Spacer()
            Text(formatSize(node.size))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let node = selection {
            FilePreviewView(node: node)
        } else {
            VStack(spacing: 4) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                Text("Select a file to preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func emptyState(message: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "internaldrive")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func formatSize(_ bytes: Int64) -> String {
        if bytes <= 0 { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private struct FilePreviewView: View {
    let node: StorageNode

    private static let maxTextBytes = 200 * 1024
    private static let maxPreviewBytes: Int64 = 10 * 1024 * 1024
    private static let textExtensions: Set<String> = ["json", "txt", "log", "md", "xml", "swift", "m", "h", "yaml", "yml", "ini", "conf", "csv", "html", "css", "js"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            body(for: node)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(node.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: 8) {
                if node.isDirectory {
                    Text("Directory")
                } else {
                    Text(formatSize(node.size))
                }
                if let modified = node.modifiedAt {
                    Text(modified.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func body(for node: StorageNode) -> some View {
        if node.isDirectory {
            Text("Folder contents appear in the tree to the left.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()
        } else if node.size > Self.maxPreviewBytes {
            VStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("File too large to preview")
                    .font(.caption.weight(.medium))
                Text(formatSize(node.size))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            renderedPreview
        }
    }

    @ViewBuilder
    private var renderedPreview: some View {
        let ext = (node.name as NSString).pathExtension.lowercased()
        let url = URL(fileURLWithPath: node.path)

        if ext == "plist" || ext == "strings" {
            PlistPreviewView(url: url)
        } else if Self.textExtensions.contains(ext) {
            TextPreviewView(url: url, byteLimit: Self.maxTextBytes)
        } else {
            HexPreviewView(url: url)
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private struct PlistEntry: Identifiable {
    let id = UUID()
    let key: String
    let value: String
}

private struct PlistPreviewView: View {
    let url: URL

    var body: some View {
        if let entries = parse() {
            Table(entries) {
                TableColumn("Key", value: \.key)
                TableColumn("Value", value: \.value)
            }
        } else {
            Text("Failed to parse plist")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func parse() -> [PlistEntry]? {
        guard let data = try? Data(contentsOf: url),
              let parsed = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return nil }

        if let dict = parsed as? [String: Any] {
            return dict.keys.sorted().map { key in
                PlistEntry(key: key, value: String(describing: dict[key] ?? ""))
            }
        }
        if let array = parsed as? [Any] {
            return array.enumerated().map { idx, value in
                PlistEntry(key: "[\(idx)]", value: String(describing: value))
            }
        }
        return [PlistEntry(key: "value", value: String(describing: parsed))]
    }
}

private struct TextPreviewView: View {
    let url: URL
    let byteLimit: Int

    @State private var text: String = ""
    @State private var truncated: Bool = false
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if truncated {
                Text("Showing first \(byteLimit) bytes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            }
            if let err = loadError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: url) { load() }
    }

    private func load() {
        do {
            let data = try Data(contentsOf: url)
            truncated = data.count > byteLimit
            let slice = truncated ? data.prefix(byteLimit) : data
            text = String(decoding: slice, as: UTF8.self)
            loadError = nil
        } catch {
            loadError = "Failed to read: \(error.localizedDescription)"
            text = ""
        }
    }
}

private struct HexPreviewView: View {
    let url: URL

    @State private var data: Data = Data()
    @State private var loadError: String?

    var body: some View {
        Group {
            if let err = loadError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                HexDumpView(data: data, byteLimit: 4096)
            }
        }
        .task(id: url) { load() }
    }

    private func load() {
        do {
            data = try Data(contentsOf: url)
            loadError = nil
        } catch {
            loadError = "Failed to read: \(error.localizedDescription)"
            data = Data()
        }
    }
}

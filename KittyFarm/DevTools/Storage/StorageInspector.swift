import Foundation

actor StorageInspector {
    private static let maxDepth = 8
    private static let skippedNames: Set<String> = [".DS_Store"]

    func capture(udid: String, bundleID: String) async throws -> StorageSnapshot {
        let rootPath = try await resolveContainer(udid: udid, bundleID: bundleID)
        let rootURL = URL(fileURLWithPath: rootPath)

        let root = walk(url: rootURL, depth: 0) ?? StorageNode(
            id: rootPath,
            name: rootURL.lastPathComponent,
            path: rootPath,
            isDirectory: true,
            size: 0,
            modifiedAt: nil,
            children: []
        )

        let prefs = readUserDefaults(rootPath: rootPath, bundleID: bundleID)

        return StorageSnapshot(
            rootPath: rootPath,
            root: root,
            userDefaults: prefs,
            capturedAt: Date()
        )
    }

    private func resolveContainer(udid: String, bundleID: String) async throws -> String {
        let result = try await ProcessRunner.run(
            XcrunUtils.simctl(["get_app_container", udid, bundleID, "data"])
        )
        try result.requireSuccess("simctl get_app_container")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func walk(url: URL, depth: Int) -> StorageNode? {
        let fm = FileManager.default
        let name = url.lastPathComponent
        if Self.skippedNames.contains(name) { return nil }

        let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: resourceKeys) else {
            print("StorageInspector: permission denied or missing \(url.path)")
            return nil
        }

        let isDir = values.isDirectory ?? false
        let modifiedAt = values.contentModificationDate
        let path = url.path

        if !isDir {
            let size = Int64(values.fileSize ?? 0)
            return StorageNode(
                id: path,
                name: name,
                path: path,
                isDirectory: false,
                size: size,
                modifiedAt: modifiedAt,
                children: nil
            )
        }

        guard depth < Self.maxDepth else {
            return StorageNode(
                id: path,
                name: name,
                path: path,
                isDirectory: true,
                size: 0,
                modifiedAt: modifiedAt,
                children: []
            )
        }

        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsSubdirectoryDescendants]
            )
        } catch {
            print("StorageInspector: cannot read directory \(path): \(error.localizedDescription)")
            return StorageNode(
                id: path,
                name: name,
                path: path,
                isDirectory: true,
                size: 0,
                modifiedAt: modifiedAt,
                children: []
            )
        }

        var children: [StorageNode] = []
        var total: Int64 = 0
        for child in contents {
            if let node = walk(url: child, depth: depth + 1) {
                total += node.size
                children.append(node)
            }
        }

        children.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return StorageNode(
            id: path,
            name: name,
            path: path,
            isDirectory: true,
            size: total,
            modifiedAt: modifiedAt,
            children: children
        )
    }

    private func readUserDefaults(rootPath: String, bundleID: String) -> [String: String] {
        let plistURL = URL(fileURLWithPath: rootPath)
            .appending(path: "Library/Preferences")
            .appending(path: "\(bundleID).plist")

        guard let data = try? Data(contentsOf: plistURL) else { return [:] }
        guard let parsed = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return [:]
        }

        var flat: [String: String] = [:]
        for (key, value) in parsed {
            flat[key] = String(describing: value)
        }
        return flat
    }
}

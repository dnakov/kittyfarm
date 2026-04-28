import Foundation

enum MCPConfigurationTarget: String, CaseIterable, Identifiable {
    case codex
    case claude
    case opencode
    case pi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .opencode: return "OpenCode"
        case .pi: return "Pi"
        }
    }

    var buttonTitle: String {
        "Add to \(displayName)"
    }

    var icon: String {
        switch self {
        case .codex: return "terminal"
        case .claude: return "sparkles"
        case .opencode: return "curlybraces"
        case .pi: return "pi"
        }
    }

    var configPath: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .codex:
            return home.appending(path: ".codex/config.toml")
        case .claude:
            return home.appending(path: "Library/Application Support/Claude/claude_desktop_config.json")
        case .opencode:
            return home.appending(path: ".config/opencode/opencode.json")
        case .pi:
            return home.appending(path: ".config/pi/mcp.json")
        }
    }
}

struct MCPConfigurationInstallResult {
    let message: String
}

enum MCPConfigurationInstaller {
    static func install(target: MCPConfigurationTarget, mcpURL: String) throws -> MCPConfigurationInstallResult {
        switch target {
        case .codex:
            try installCodex(mcpURL: mcpURL, at: target.configPath)
        case .claude:
            try installClaude(mcpURL: mcpURL, at: target.configPath)
        case .opencode:
            try installOpenCode(mcpURL: mcpURL, at: target.configPath)
        case .pi:
            try installPi(mcpURL: mcpURL, at: target.configPath)
        }

        return MCPConfigurationInstallResult(
            message: "Added KittyFarm MCP to \(target.displayName): \(target.configPath.path)"
        )
    }

    private static func installCodex(mcpURL: String, at url: URL) throws {
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let block = """

        [mcp_servers.kittyfarm]
        url = "\(tomlString(mcpURL))"
        enabled = true
        """

        if let range = tomlTableRange(named: "mcp_servers.kittyfarm", in: text) {
            text.replaceSubrange(range, with: block.trimmingCharacters(in: .newlines))
        } else {
            if !text.isEmpty, !text.hasSuffix("\n") {
                text.append("\n")
            }
            text.append(block)
            text.append("\n")
        }

        try write(text.data(using: .utf8) ?? Data(), to: url)
    }

    private static func installClaude(mcpURL: String, at url: URL) throws {
        var json = try loadJSONObject(at: url)
        var servers = json["mcpServers"] as? [String: Any] ?? [:]
        servers["kittyfarm"] = [
            "type": "http",
            "url": mcpURL,
        ]
        json["mcpServers"] = servers
        try writeJSON(json, to: url)
    }

    private static func installOpenCode(mcpURL: String, at url: URL) throws {
        var json = try loadJSONObject(at: url)
        var servers = json["mcp"] as? [String: Any] ?? [:]
        servers["kittyfarm"] = [
            "type": "remote",
            "url": mcpURL,
            "enabled": true,
            "oauth": false,
        ]
        json["mcp"] = servers
        try writeJSON(json, to: url)
    }

    private static func installPi(mcpURL: String, at url: URL) throws {
        var json = try loadJSONObject(at: url)
        var servers = json["mcpServers"] as? [String: Any] ?? [:]
        servers["kittyfarm"] = [
            "type": "http",
            "url": mcpURL,
        ]
        json["mcpServers"] = servers
        try writeJSON(json, to: url)
    }

    private static func loadJSONObject(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    private static func writeJSON(_ json: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try write(data, to: url)
    }

    private static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try backup(url)
        try data.write(to: url, options: .atomic)
    }

    private static func backup(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let backupURL = url.deletingLastPathComponent()
            .appending(path: "\(url.lastPathComponent).kittyfarm-backup")
        try? FileManager.default.removeItem(at: backupURL)
        try FileManager.default.copyItem(at: url, to: backupURL)
    }

    private static func tomlTableRange(named tableName: String, in text: String) -> Range<String.Index>? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var cursor = text.startIndex
        var start: String.Index?
        var end: String.Index?

        for line in lines {
            let lineStart = cursor
            let lineEnd = text.index(lineStart, offsetBy: line.count)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "[\(tableName)]" {
                start = lineStart
            } else if start != nil, trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                end = lineStart
                break
            }

            cursor = lineEnd
            if cursor < text.endIndex {
                cursor = text.index(after: cursor)
            }
        }

        guard let start else { return nil }
        return start..<(end ?? text.endIndex)
    }

    private static func tomlString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

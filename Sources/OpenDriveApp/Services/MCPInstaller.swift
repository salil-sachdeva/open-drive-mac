import Foundation

/// Writes `open-drive-mcp` server configuration into Claude Desktop, Cursor, or Claude Code CLI.
public enum MCPInstaller {
    public static func installForClaudeDesktop(mcpBinaryPath: String) throws -> URL {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        try upsertMCPConfig(at: configURL, binaryPath: mcpBinaryPath)
        return configURL
    }

    public static func installForCursor(mcpBinaryPath: String) throws -> URL {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/mcp.json")
        try upsertMCPConfig(at: configURL, binaryPath: mcpBinaryPath)
        return configURL
    }

    public static func claudeCodeCLICommand(mcpBinaryPath: String) -> String {
        "claude mcp add --scope user opendrive -- \"\(mcpBinaryPath)\""
    }

    private static func upsertMCPConfig(at url: URL, binaryPath: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var root: [String: Any] = [:]
        if let existingData = try? Data(contentsOf: url),
           let existingObj = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            root = existingObj
        }
        var mcpServers = root["mcpServers"] as? [String: Any] ?? [:]
        mcpServers["opendrive"] = [
            "command": binaryPath,
            "args": [] as [String]
        ]
        root["mcpServers"] = mcpServers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

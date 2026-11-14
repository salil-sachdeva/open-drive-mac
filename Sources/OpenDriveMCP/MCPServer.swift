import Foundation
import OpenDriveCore

/// Standalone JSON-RPC 2.0 `stdio` Model Context Protocol (MCP) server (`open-drive-mcp`).
/// Exposes `list_folder`, `search_files`, `read_file` (up to 4 MiB byte range), and `write_file`
/// strictly scoped to `~/Library/Open Drive`.
public struct MCPServer {
    public static let maxReadLength = 4 * 1024 * 1024 // 4 MiB cap per read call
    public let rootURL: URL

    public init(rootURL: URL = OpenDrivePaths.mountRootURL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public func runStdioLoop() {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let reqData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: reqData) as? [String: Any] else {
                continue
            }
            if let response = handleRequest(json),
               let respData = try? JSONSerialization.data(withJSONObject: response),
               let respStr = String(data: respData, encoding: .utf8) {
                print(respStr)
                fflush(stdout)
            }
        }
    }

    public func handleRequest(_ request: [String: Any]) -> [String: Any]? {
        let id = request["id"]
        guard let method = request["method"] as? String else {
            return nil
        }
        let params = request["params"] as? [String: Any] ?? [:]

        switch method {
        case "notifications/initialized":
            return nil

        case "initialize":
            return [
                "jsonrpc": "2.0",
                "id": id as Any,
                "result": [
                    "protocolVersion": "2024-11-05",
                    "serverInfo": [
                        "name": "open-drive-mcp",
                        "version": "1.0.0"
                    ],
                    "capabilities": [
                        "tools": [:] as [String: Any]
                    ]
                ]
            ]

        case "tools/list":
            return [
                "jsonrpc": "2.0",
                "id": id as Any,
                "result": [
                    "tools": Self.toolDefinitions
                ]
            ]

        case "tools/call":
            guard let toolName = params["name"] as? String else {
                return errorResponse(id: id, code: -32602, message: "Missing tool name")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try executeTool(name: toolName, arguments: args)
                return [
                    "jsonrpc": "2.0",
                    "id": id as Any,
                    "result": [
                        "content": [
                            ["type": "text", "text": text]
                        ],
                        "isError": false
                    ]
                ]
            } catch {
                return [
                    "jsonrpc": "2.0",
                    "id": id as Any,
                    "result": [
                        "content": [
                            ["type": "text", "text": "Error: \(error.localizedDescription)"]
                        ],
                        "isError": true
                    ]
                ]
            }

        default:
            return errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Path Validation & Tool Execution

    public func resolveSafeURL(relativePath: String) throws -> URL {
        let cleaned = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidate = cleaned.isEmpty
            ? rootURL
            : rootURL.appendingPathComponent(cleaned).standardizedFileURL

        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard candidate.path == rootURL.path || candidate.path.hasPrefix(rootPrefix) else {
            throw NSError(domain: "OpenDriveMCP", code: 403, userInfo: [
                NSLocalizedDescriptionKey: "path escapes Open Drive: \(relativePath)"
            ])
        }
        for component in candidate.pathComponents {
            if component == ".Trash" || component == ".opendrive" {
                throw NSError(domain: "OpenDriveMCP", code: 403, userInfo: [
                    NSLocalizedDescriptionKey: "access to \(component) is restricted"
                ])
            }
        }
        return candidate
    }

    private func executeTool(name: String, arguments: [String: Any]) throws -> String {
        switch name {
        case "list_folder":
            let rel = arguments["path"] as? String ?? ""
            let dirURL = try resolveSafeURL(relativePath: rel)
            let contents = try FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            let lines: [String] = contents.map { url in
                let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let isDir = vals?.isDirectory ?? false
                let size = vals?.fileSize ?? 0
                return isDir ? "[DIR]  \(url.lastPathComponent)/" : "[FILE] \(url.lastPathComponent) (\(size) bytes)"
            }.sorted()
            return lines.isEmpty ? "(empty folder)" : lines.joined(separator: "\n")

        case "search_files":
            let query = (arguments["query"] as? String ?? "").lowercased()
            let rel = arguments["path"] as? String ?? ""
            let startURL = try resolveSafeURL(relativePath: rel)
            var matches: [String] = []
            if let enumerator = FileManager.default.enumerator(
                at: startURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let fileURL as URL in enumerator {
                    if fileURL.lastPathComponent.lowercased().contains(query) {
                        let relPath = fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
                        matches.append(relPath)
                        if matches.count >= 100 { break }
                    }
                }
            }
            return matches.isEmpty ? "No matching files found." : matches.joined(separator: "\n")

        case "read_file":
            guard let rel = arguments["path"] as? String else {
                throw NSError(domain: "OpenDriveMCP", code: 400, userInfo: [NSLocalizedDescriptionKey: "Missing 'path'"])
            }
            let fileURL = try resolveSafeURL(relativePath: rel)
            let offset = (arguments["offset"] as? NSNumber)?.uint64Value ?? 0
            let requestedLen = (arguments["length"] as? NSNumber)?.intValue ?? Self.maxReadLength
            let clampedLen = min(max(1, requestedLen), Self.maxReadLength)

            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: clampedLen) ?? Data()
            if let text = String(data: data, encoding: .utf8) {
                return text
            }
            return data.base64EncodedString()

        case "write_file":
            guard let rel = arguments["path"] as? String,
                  let content = arguments["content"] as? String else {
                throw NSError(domain: "OpenDriveMCP", code: 400, userInfo: [
                    NSLocalizedDescriptionKey: "Missing 'path' or 'content'"
                ])
            }
            let fileURL = try resolveSafeURL(relativePath: rel)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(content.utf8).write(to: fileURL, options: .atomic)
            return "Wrote \(content.utf8.count) bytes to \(rel)"

        default:
            throw NSError(domain: "OpenDriveMCP", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Unknown tool: \(name)"
            ])
        }
    }

    private func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id as Any,
            "error": [
                "code": code,
                "message": message
            ]
        ]
    }

    private static var toolDefinitions: [[String: Any]] {
        [
            [
                "name": "list_folder",
                "description": "List files and folders inside ~/Library/Open Drive at the given relative path.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Relative path inside Open Drive (empty string for root)."]
                    ]
                ]
            ],
            [
                "name": "search_files",
                "description": "Search for files by filename substring inside ~/Library/Open Drive.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Case-insensitive filename substring to search for."],
                        "path": ["type": "string", "description": "Optional relative directory path to scope the search."]
                    ],
                    "required": ["query"]
                ]
            ],
            [
                "name": "read_file",
                "description": "Read text or binary byte range (up to 4 MiB per call) from a file in ~/Library/Open Drive.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Relative path to the file."],
                        "offset": ["type": "integer", "description": "Byte offset to start reading from (default 0)."],
                        "length": ["type": "integer", "description": "Number of bytes to read (capped at 4194304)."]
                    ],
                    "required": ["path"]
                ]
            ],
            [
                "name": "write_file",
                "description": "Write UTF-8 text content to a file inside ~/Library/Open Drive.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Relative path to write."],
                        "content": ["type": "string", "description": "UTF-8 file contents."]
                    ],
                    "required": ["path", "content"]
                ]
            ]
        ]
    }
}

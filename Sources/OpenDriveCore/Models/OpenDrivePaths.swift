import Foundation

/// Well-known file names, constants and on-disk locations used by Open Drive.
public enum OpenDrivePaths {
    // MARK: - Constants

    public static let defaultDriveName = "Open Drive"
    public static let fsShortName = "opendrive"
    public static let appGroupIdentifier = "group.org.opendrive.mac"
    public static let keychainAccessGroup = "org.opendrive.mac.shared"
    public static let refreshTriggerFileName = ".od-refresh"
    public static let metaFileName = ".od-meta"
    public static let trashFolderName = "Open Drive Trash"
    public static let defaultChunkSize: Int = 4 * 1024 * 1024 // 4 MiB

    // MARK: - Locations

    public static var mountsContainerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("OpenDrive", isDirectory: true)
    }

    public static var legacyMountRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Open Drive", isDirectory: true)
    }

    public static var mountRootURL: URL {
        mountURL(forDriveName: SharedSettings.shared.mountedDriveName)
    }

    public static func sanitizeDriveName(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for forbidden in ["/", ":", "\\", "\0"] {
            cleaned = cleaned.replacingOccurrences(of: forbidden, with: "-")
        }
        cleaned = cleaned
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        while cleaned.hasPrefix(".") || cleaned.hasPrefix(" ") {
            cleaned.removeFirst()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 64 {
            cleaned = String(cleaned.prefix(64)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned.isEmpty ? defaultDriveName : cleaned
    }

    public static func mountURL(forDriveName name: String) -> URL {
        mountsContainerURL.appendingPathComponent(sanitizeDriveName(name), isDirectory: true)
    }

    public static var appSupportRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("OpenDrive", isDirectory: true)
    }

    public static var cacheRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("OpenDrive", isDirectory: true)
    }

    public static var chunksCacheURL: URL {
        cacheRootURL.appendingPathComponent("chunks", isDirectory: true)
    }

    public static var scratchCacheURL: URL {
        cacheRootURL.appendingPathComponent("tmp", isDirectory: true)
    }

    public static func sanitizeAccountId(_ raw: String) -> String {
        var cleaned = raw.map { ch -> Character in
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-") {
                return ch
            }
            return "_"
        }
        var result = String(cleaned)
        while result.contains("..") {
            result = result.replacingOccurrences(of: "..", with: "__")
        }
        while result.hasPrefix(".") {
            result.removeFirst()
        }
        cleaned = []
        return result.isEmpty ? "account" : String(result.prefix(128))
    }

    public static func createPrivateDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    public static func setPrivateFilePermissions(at url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func writePrivateFile(_ data: Data, to url: URL) throws {
        try createPrivateDirectory(at: url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        setPrivateFilePermissions(at: url)
    }

    public static func databaseURL(for accountId: String) -> URL {
        appSupportRootURL
            .appendingPathComponent("db", isDirectory: true)
            .appendingPathComponent("\(sanitizeAccountId(accountId)).sqlite", isDirectory: false)
    }

    public static var accountsRegistryURL: URL {
        appSupportRootURL.appendingPathComponent("accounts.json", isDirectory: false)
    }
}

import Foundation

/// Well-known file names, constants and on-disk locations used by Open Drive.
public enum OpenDrivePaths {
    // MARK: - Constants

    public static let fsShortName = "opendrive"
    public static let refreshTriggerFileName = ".fd-refresh"
    public static let metaFileName = ".fd-meta"
    public static let trashFolderName = "Open Drive Trash"
    public static let defaultChunkSize: Int = 4 * 1024 * 1024 // 4 MiB

    // MARK: - Locations

    public static var mountRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Open Drive", isDirectory: true)
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

    public static func databaseURL(for accountId: String) -> URL {
        appSupportRootURL
            .appendingPathComponent("db", isDirectory: true)
            .appendingPathComponent("\(accountId).sqlite", isDirectory: false)
    }

    public static var accountsRegistryURL: URL {
        appSupportRootURL.appendingPathComponent("accounts.json", isDirectory: false)
    }
}

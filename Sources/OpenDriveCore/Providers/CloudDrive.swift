import Foundation

// MARK: - Remote Change Models

/// A single remote change reported by a provider's change feed.
public struct RemoteChangeEvent: Sendable, Equatable {
    public let driveId: String
    public let removed: Bool
    public let item: DriveItem?

    public init(driveId: String, removed: Bool, item: DriveItem?) {
        self.driveId = driveId
        self.removed = removed
        self.item = item
    }
}

/// One page of remote changes plus the cursors needed to continue or resume polling.
public struct RemoteDeltaPage: Sendable {
    public let events: [RemoteChangeEvent]
    public let nextPageToken: String?
    public let newStartPageToken: String?

    public init(events: [RemoteChangeEvent], nextPageToken: String?, newStartPageToken: String?) {
        self.events = events
        self.nextPageToken = nextPageToken
        self.newStartPageToken = newStartPageToken
    }
}

/// Reported storage capacity and usage for a remote cloud account.
public struct CloudStorageQuota: Codable, Sendable, Equatable {
    public let limit: Int64?
    public let usage: Int64?

    public init(limit: Int64?, usage: Int64?) {
        self.limit = limit
        self.usage = usage
    }

    public var totalBytes: Int64? {
        limit.flatMap { $0 > 0 ? $0 : nil }
    }

    public var usedBytes: Int64 {
        max(0, usage ?? 0)
    }

    public var availableBytes: Int64? {
        totalBytes.map { max(0, $0 - usedBytes) }
    }

    public var usedFraction: Double? {
        totalBytes.map { min(1.0, max(0.0, Double(usedBytes) / Double($0))) }
    }

    public var isUnlimited: Bool {
        totalBytes == nil
    }
}

// MARK: - CloudDrive

/// Abstraction over a remote cloud storage provider.
public protocol CloudDrive: Sendable {
    func fetchUserEmail() async throws -> String
    func fetchStorageQuota() async throws -> CloudStorageQuota?
    func resolveRootFolderId() async throws -> String
    func ensureWorkspace(wholeDrive: Bool) async throws -> (rootId: String, trashId: String?, startPageToken: String)
    func listChildren(folderId: String) async throws -> [DriveItem]
    func fetchItemMetadata(driveId: String) async throws -> DriveItem?
    func fetchChanges(pageToken: String) async throws -> RemoteDeltaPage
    func downloadByteRange(driveId: String, offset: Int64, length: Int) async throws -> Data
    func createFolder(name: String, parentId: String, isEncrypted: Bool, origClearName: String?) async throws -> DriveItem
    func renameOrMove(driveId: String, newName: String?, addParentId: String?, removeParentId: String?) async throws -> DriveItem
    func moveToTrash(driveId: String, trashFolderId: String?, currentParentId: String?) async throws
    func startResumableUpload(
        name: String,
        parentId: String,
        targetDriveId: String?,
        mime: String,
        totalSize: Int64,
        isEncrypted: Bool
    ) async throws -> URL
    func uploadResumableChunk(
        sessionURL: URL,
        chunkData: Data,
        offset: Int64,
        totalSize: Int64
    ) async throws -> (nextOffset: Int64, completedItem: DriveItem?)
    func fetchKeyBundle(rootId: String) async throws -> (metaDriveId: String, bundle: KeyBundle)?
    func uploadKeyBundle(_ bundle: KeyBundle, rootId: String, existingMetaId: String?) async throws -> String
    func updatePosixMode(driveId: String, mode: UInt32) async throws
    func createSymlink(name: String, target: String, parentId: String, isEncrypted: Bool, origClearName: String?) async throws -> DriveItem
}

// MARK: - Default Implementations

extension CloudDrive {
    public func fetchStorageQuota() async throws -> CloudStorageQuota? {
        nil
    }

    public func resolveRootFolderId() async throws -> String {
        "root"
    }

    public func fetchKeyBundle(rootId: String) async throws -> (metaDriveId: String, bundle: KeyBundle)? {
        nil
    }

    public func uploadKeyBundle(_ bundle: KeyBundle, rootId: String, existingMetaId: String?) async throws -> String {
        "meta-\(UUID().uuidString.prefix(8))"
    }

    public func updatePosixMode(driveId: String, mode: UInt32) async throws {}

    public func createSymlink(name: String, target: String, parentId: String, isEncrypted: Bool, origClearName: String?) async throws -> DriveItem {
        throw POSIXError(.ENOTSUP)
    }
}

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

// MARK: - CloudDrive

/// Abstraction over a remote cloud storage provider.
public protocol CloudDrive: Sendable {
    func fetchUserEmail() async throws -> String
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
}

// MARK: - Default Implementations

extension CloudDrive {
    public func fetchKeyBundle(rootId: String) async throws -> (metaDriveId: String, bundle: KeyBundle)? {
        nil
    }

    public func uploadKeyBundle(_ bundle: KeyBundle, rootId: String, existingMetaId: String?) async throws -> String {
        "meta-\(UUID().uuidString.prefix(8))"
    }
}

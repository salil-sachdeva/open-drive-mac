import CryptoKit
import Foundation

/// Polls Google Drive changes (`changesPageToken`), performs initial and on-demand folder hydration,
/// and reconciles remote updates into `MetadataStore` while protecting recent `localChanges`.
public actor SyncEngine {
    private let accountId: String
    private let store: MetadataStore
    private let client: any CloudDrive
    private let cache: ChunkCache
    private var hydratedFolderIds: Set<String> = []

    public init(
        accountId: String,
        store: MetadataStore,
        client: any CloudDrive,
        cache: ChunkCache
    ) {
        self.accountId = accountId
        self.store = store
        self.client = client
        self.cache = cache
    }

    /// Hydrates a specific folder from Google Drive if it hasn't been listed in this session yet.
    @discardableResult
    public func hydrateFolderIfNeeded(
        folderId: String,
        force: Bool = false,
        masterKey: SymmetricKey? = nil
    ) async throws -> [DriveItem] {
        if !force && hydratedFolderIds.contains(folderId) {
            return try await store.listChildren(parentId: folderId)
        }
        let account = try await store.fetchAccount(id: accountId)
        let trashId = account?.trashId
        let metaId = account?.metaId

        let remoteChildren = try await client.listChildren(folderId: folderId)
        for rawItem in remoteChildren {
            if rawItem.name == OpenDrivePaths.metaFileName || rawItem.driveId == trashId || rawItem.driveId == metaId {
                continue
            }
            if rawItem.isGoogleWorkspaceVirtualDocument {
                continue
            }
            if try await store.wasRecentlyModifiedLocally(driveId: rawItem.driveId, withinSeconds: 10) {
                continue
            }
            let item = VaultCrypto.decryptRemoteMetadata(rawItem, masterKey: masterKey)
            try await store.upsertItem(item)
        }
        hydratedFolderIds.insert(folderId)
        return try await store.listChildren(parentId: folderId)
    }

    /// Performs initial root hydration (if needed) and incremental delta sync via `changesPageToken`.
    @discardableResult
    public func pullRemoteChanges(masterKey: SymmetricKey? = nil) async throws -> Int {
        guard var account = try await store.fetchAccount(id: accountId) else {
            return 0
        }
        guard let rootId = account.rootId else {
            return 0
        }

        var appliedCount = 0

        if !hydratedFolderIds.contains(rootId) {
            try? await store.purgeGoogleWorkspaceVirtualDocuments()
            let hydrated = try await hydrateFolderIfNeeded(folderId: rootId, force: true, masterKey: masterKey)
            appliedCount += hydrated.count
        }

        if let token = account.changesPageToken {
            var cursor: String? = token
            while let currentToken = cursor {
                let page = try await client.fetchChanges(pageToken: currentToken)
                for event in page.events {
                    if try await store.wasRecentlyModifiedLocally(driveId: event.driveId, withinSeconds: 10) {
                        continue
                    }
                    if event.driveId == account.trashId || event.driveId == account.metaId {
                        continue
                    }

                    if event.removed {
                        try await store.deleteItem(driveId: event.driveId)
                        await cache.invalidate(driveId: event.driveId)
                        appliedCount += 1
                    } else if let rawItem = event.item {
                        if rawItem.name == OpenDrivePaths.metaFileName {
                            continue
                        }
                        if rawItem.isGoogleWorkspaceVirtualDocument {
                            try? await store.deleteItem(driveId: rawItem.driveId)
                            continue
                        }
                        let item = VaultCrypto.decryptRemoteMetadata(rawItem, masterKey: masterKey)
                        if let existing = try await store.fetchItem(driveId: item.driveId),
                           existing.contentVersionToken != item.contentVersionToken {
                            await cache.invalidate(driveId: item.driveId)
                        }
                        try await store.upsertItem(item)
                        appliedCount += 1
                    }
                }
                if let newStart = page.newStartPageToken {
                    account.changesPageToken = newStart
                    try await store.upsertAccount(account)
                }
                cursor = page.nextPageToken
            }
        }

        if appliedCount > 0 {
            DarwinNotifier.shared.post(.pulled)
        }
        return appliedCount
    }
}

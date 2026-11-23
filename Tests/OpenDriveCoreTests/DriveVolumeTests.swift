import XCTest
@testable import OpenDriveCore

final class DriveVolumeTests: XCTestCase {
    func testDriveVolumeScratchWriteCommitAndConflictResolution() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try MetadataStore(databaseURL: tempDir.appendingPathComponent("vol.sqlite"))
        let cache = try ChunkCache(cacheDirectory: tempDir.appendingPathComponent("chunks"))
        let mockDrive = MockGoogleDrive()
        let account = CloudAccount(
            id: "gdrive-1",
            displayName: "Personal Drive",
            rootId: "root-folder-id",
            trashId: "trash-folder-id"
        )
        try await store.upsertAccount(account)

        let reader = RangeReader(cache: cache) { driveId, offset, length in
            try await mockDrive.downloadByteRange(driveId: driveId, offset: offset, length: length)
        }
        let uploader = UploadEngine(store: store, client: mockDrive)
        let syncer = SyncEngine(accountId: account.id, store: store, client: mockDrive, cache: cache)
        let volume = try DriveVolume(scratchDirectory: tempDir.appendingPathComponent("scratch"))

        await volume.registerCloudStack(
            DriveVolume.MountedCloudStack(
                account: account,
                store: store,
                client: mockDrive,
                reader: reader,
                uploader: uploader,
                syncer: syncer
            )
        )

        let initialDirect = await volume.allowsDirectRootMutations()
        XCTAssertTrue(initialDirect, "Single connected account must flatten root directly")

        let initialRootChildren = try await volume.listDirectory(itemId: DriveVolume.rootItemId)
        XCTAssertEqual(initialRootChildren.count, 0)

        let createdFile = try await volume.createItem(
            name: "notes.txt",
            isDirectory: false,
            inDirectory: DriveVolume.rootItemId
        )
        let payload = Data("Hello from Open Drive FSKit!".utf8)
        let written = try await volume.write(itemId: createdFile.itemId, offset: 0, data: payload)
        XCTAssertEqual(written, payload.count)
        try await volume.closeAndCommitIfDirty(itemId: createdFile.itemId)

        let listedAfterUpload = try await volume.listDirectory(itemId: DriveVolume.rootItemId)
        XCTAssertEqual(listedAfterUpload.map(\.name), ["notes.txt"])
        let readBack = try await volume.read(itemId: listedAfterUpload[0].itemId, offset: 0, length: 100)
        XCTAssertEqual(readBack, payload)

        // 4. Truncate via setAttributes (partial shrink, mtime update, and truncate to 0)
        let uploadedNode = listedAfterUpload[0]
        let truncatedNode = try await volume.setAttributes(
            itemId: uploadedNode.itemId,
            newSize: 5,
            modifiedTime: 1_700_000_000
        )
        XCTAssertEqual(truncatedNode.size, 5)
        XCTAssertEqual(truncatedNode.modifiedTime, 1_700_000_000)
        let truncatedData = try await volume.read(itemId: uploadedNode.itemId, offset: 0, length: 100)
        XCTAssertEqual(truncatedData, Data("Hello".utf8))

        let zeroNode = try await volume.setAttributes(itemId: uploadedNode.itemId, newSize: 0, modifiedTime: nil)
        XCTAssertEqual(zeroNode.size, 0)
        try await volume.closeAndCommitIfDirty(itemId: uploadedNode.itemId)

        // 5. Proactive offline pinning caches uncached chunks into ChunkCache
        let pinnedItem = DriveItem(
            driveId: "pin-doc-1",
            parentId: "root-folder-id",
            name: "offline-guide.txt",
            isFolder: false,
            size: 1024,
            version: "v1",
            pinned: true
        )
        let guideData = Data(repeating: 0x5A, count: 1024)
        await mockDrive.seedFile(item: pinnedItem, data: guideData)
        try await store.upsertItem(pinnedItem)

        await volume.warmPinnedItems()
        let isCached = await cache.contains(ChunkKey(driveId: "pin-doc-1", contentVersion: "v1", index: 0))
        XCTAssertTrue(isCached, "Pinned item chunk must be pre-cached by warmPinnedItems")

        // 6. Live storageQuota aggregation in DriveVolume
        let beforeQuota = await volume.aggregatedStorageQuota()
        XCTAssertNil(beforeQuota)

        await mockDrive.setSimulatedQuota(CloudStorageQuota(limit: 100_000_000, usage: 25_000_000))
        await volume.refreshStorageQuotas()
        let quota = await volume.aggregatedStorageQuota()
        XCTAssertEqual(quota?.totalBytes, 100_000_000)
        XCTAssertEqual(quota?.usedBytes, 25_000_000)
        XCTAssertEqual(quota?.availableBytes, 75_000_000)

        // 7. CloudStorageQuota computed properties (normal, over-quota clamped, unlimited)
        let normalQuota = CloudStorageQuota(limit: 1_000, usage: 250)
        XCTAssertEqual(normalQuota.totalBytes, 1_000)
        XCTAssertEqual(normalQuota.usedBytes, 250)
        XCTAssertEqual(normalQuota.availableBytes, 750)
        XCTAssertEqual(normalQuota.usedFraction ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertFalse(normalQuota.isUnlimited)

        let overQuota = CloudStorageQuota(limit: 1_000, usage: 1_500)
        XCTAssertEqual(overQuota.availableBytes, 0)
        XCTAssertEqual(overQuota.usedFraction ?? -1, 1.0, accuracy: 0.0001)

        let unlimitedQuota = CloudStorageQuota(limit: nil, usage: 5_000)
        XCTAssertNil(unlimitedQuota.totalBytes)
        XCTAssertNil(unlimitedQuota.availableBytes)
        XCTAssertNil(unlimitedQuota.usedFraction)
        XCTAssertEqual(unlimitedQuota.usedBytes, 5_000)
        XCTAssertTrue(unlimitedQuota.isUnlimited)

        // 8. Partial-cache regression: remote children hydrate even when SQLite already has an item
        let partialFolder = DriveItem(
            driveId: "partial-folder",
            parentId: "root-folder-id",
            name: "SharedDocs",
            isFolder: true
        )
        let localPartialChild = DriveItem(
            driveId: "partial-local-1",
            parentId: "partial-folder",
            name: "LocalCached.txt",
            isFolder: false,
            size: 12
        )
        let remoteUnseenChild = DriveItem(
            driveId: "partial-remote-2",
            parentId: "partial-folder",
            name: "RemoteExisting.pdf",
            isFolder: false,
            size: 2048
        )
        try await store.upsertItem(partialFolder)
        try await store.upsertItem(localPartialChild)
        await mockDrive.seedFile(item: partialFolder, data: Data())
        await mockDrive.seedFile(item: localPartialChild, data: Data("LocalCached!".utf8))
        await mockDrive.seedFile(item: remoteUnseenChild, data: Data(repeating: 0x2A, count: 2048))

        let folderNode = try await volume.lookup(name: "SharedDocs", inDirectory: DriveVolume.rootItemId)
        let partialChildren = try await volume.listDirectory(itemId: folderNode.itemId)
        let partialNames = Set(partialChildren.map(\.name))
        XCTAssertTrue(partialNames.contains("LocalCached.txt"))
        XCTAssertTrue(partialNames.contains("RemoteExisting.pdf"), "Existing remote files must hydrate even if folder already had cached items")

        // 9. Multi-account mode switches back to per-account top-level folders
        let secondAccount = CloudAccount(
            id: "gdrive-2",
            displayName: "Work Drive",
            rootId: "work-root-id",
            trashId: "work-trash-id"
        )
        let store2 = try MetadataStore(databaseURL: tempDir.appendingPathComponent("vol2.sqlite"))
        try await store2.upsertAccount(secondAccount)
        await volume.registerCloudStack(
            DriveVolume.MountedCloudStack(
                account: secondAccount,
                store: store2,
                client: mockDrive,
                reader: reader,
                uploader: UploadEngine(store: store2, client: mockDrive),
                syncer: SyncEngine(accountId: secondAccount.id, store: store2, client: mockDrive, cache: cache)
            )
        )
        let multiDirect = await volume.allowsDirectRootMutations()
        XCTAssertFalse(multiDirect, "Multiple connected accounts must disable flattened root mutations")
        let multiRootChildren = try await volume.listDirectory(itemId: DriveVolume.rootItemId)
        XCTAssertEqual(multiRootChildren.map(\.name), ["Personal Drive", "Work Drive"])
    }
}

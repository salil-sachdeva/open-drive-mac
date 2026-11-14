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

        let rootChildren = try await volume.listDirectory(itemId: DriveVolume.rootItemId)
        XCTAssertEqual(rootChildren.count, 1)
        let cloudRoot = rootChildren[0]
        XCTAssertEqual(cloudRoot.name, "Personal Drive")

        let createdFile = try await volume.createItem(
            name: "notes.txt",
            isDirectory: false,
            inDirectory: cloudRoot.itemId
        )
        let payload = Data("Hello from Open Drive FSKit!".utf8)
        let written = try await volume.write(itemId: createdFile.itemId, offset: 0, data: payload)
        XCTAssertEqual(written, payload.count)
        try await volume.closeAndCommitIfDirty(itemId: createdFile.itemId)

        let listedAfterUpload = try await volume.listDirectory(itemId: cloudRoot.itemId)
        XCTAssertEqual(listedAfterUpload.map(\.name), ["notes.txt"])
        let readBack = try await volume.read(itemId: listedAfterUpload[0].itemId, offset: 0, length: 100)
        XCTAssertEqual(readBack, payload)
    }
}

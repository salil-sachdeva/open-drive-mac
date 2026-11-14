import XCTest
@testable import OpenDriveCore

final class SyncEngineTests: XCTestCase {
    func testSyncEngineHydrationAndLocalChangesRaceProtection() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try MetadataStore(databaseURL: tempDir.appendingPathComponent("sync.sqlite"))
        let cache = try ChunkCache(cacheDirectory: tempDir.appendingPathComponent("chunks"))
        let mockDrive = MockGoogleDrive()

        let account = CloudAccount(
            id: "sync-acc-1",
            displayName: "Work Drive",
            rootId: "root-folder-id",
            trashId: "trash-folder-id",
            changesPageToken: "page-token-1"
        )
        try await store.upsertAccount(account)

        let remoteDoc = DriveItem(
            driveId: "doc-1",
            parentId: "root-folder-id",
            name: "Spec.md",
            isFolder: false,
            size: 128,
            version: "v1"
        )
        let subFolder = DriveItem(
            driveId: "sub-1",
            parentId: "root-folder-id",
            name: "Designs",
            isFolder: true,
            size: 0,
            version: "v1"
        )
        let nestedFile = DriveItem(
            driveId: "nested-1",
            parentId: "sub-1",
            name: "Mockup.fig",
            isFolder: false,
            size: 2048,
            version: "v1"
        )
        await mockDrive.seedFile(item: remoteDoc, data: Data("v1".utf8))
        await mockDrive.seedFile(item: subFolder, data: Data())
        await mockDrive.seedFile(item: nestedFile, data: Data("fig".utf8))

        let syncer = SyncEngine(accountId: account.id, store: store, client: mockDrive, cache: cache)

        let count = try await syncer.pullRemoteChanges()
        XCTAssertEqual(count, 2)

        let subChildren = try await syncer.hydrateFolderIfNeeded(folderId: "sub-1")
        XCTAssertEqual(subChildren.map(\.name), ["Mockup.fig"])

        try await store.recordLocalChange(driveId: "doc-1")
        await mockDrive.setSimulatedChanges([
            RemoteChangeEvent(driveId: "doc-1", removed: true, item: nil)
        ])
        _ = try await syncer.pullRemoteChanges()
        let protectedItem = try await store.fetchItem(driveId: "doc-1")
        XCTAssertNotNil(protectedItem, "Recently modified local item must be protected from stale remote deletion")
    }
}

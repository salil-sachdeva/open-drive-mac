import XCTest
@testable import OpenDriveCore

final class MetadataStoreTests: XCTestCase {
    func testMetadataStoreSchemaDisambiguationAndSearch() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try MetadataStore(databaseURL: tempDir.appendingPathComponent("test.sqlite"))
        let account = CloudAccount(
            id: "acc-1",
            displayName: "Work Google Drive",
            email: "user@example.com",
            rootId: "root-1",
            trashId: "trash-1",
            changesPageToken: "100",
            encryptionEnabled: true
        )
        try await store.upsertAccount(account)
        let fetchedAcc = try await store.fetchAccount(id: "acc-1")
        XCTAssertEqual(fetchedAcc, account)

        let first = DriveItem(driveId: "id-alpha1", parentId: "root-1", name: "Report.pdf", isFolder: false, size: 1024)
        let second = DriveItem(driveId: "id-beta22", parentId: "root-1", name: "report.PDF", isFolder: false, size: 2048)
        try await store.upsertItem(first)
        try await store.upsertItem(second)

        let children = try await store.listChildren(parentId: "root-1")
        XCTAssertEqual(children.count, 2)
        let shownNames = Set(children.map(\.shownAs))
        XCTAssertTrue(shownNames.contains("Report.pdf"))
        XCTAssertTrue(shownNames.contains("report (id-bet).PDF"))

        let hits = try await store.searchItems(query: "Report")
        XCTAssertEqual(hits.count, 2)
    }
}

import SQLite3
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

        // Preserve pinned flag across remote delta upsert
        try await store.setPinned(driveId: "id-alpha1", pinned: true)
        var syncedUpdate = first
        syncedUpdate.size = 4096
        syncedUpdate.pinned = false
        try await store.upsertItem(syncedUpdate)
        let refetchedPinned = try await store.fetchItem(driveId: "id-alpha1")
        XCTAssertEqual(refetchedPinned?.pinned, true, "Remote delta updates must preserve local pinned state")
        XCTAssertEqual(refetchedPinned?.size, 4096)

        // Multi-level nested relative path reconstruction (`resolveRelativePathComponents`)
        let folderA = DriveItem(driveId: "folder-a", parentId: "root-1", name: "Projects", isFolder: true)
        let folderB = DriveItem(driveId: "folder-b", parentId: "folder-a", name: "OpenDrive", isFolder: true)
        let deepDoc = DriveItem(driveId: "deep-doc", parentId: "folder-b", name: "Roadmap.md", isFolder: false)
        try await store.upsertItem(folderA)
        try await store.upsertItem(folderB)
        try await store.upsertItem(deepDoc)

        let components = try await store.resolveRelativePathComponents(for: deepDoc, rootId: "root-1")
        XCTAssertEqual(components, ["Projects", "OpenDrive", "Roadmap.md"])

        // Slash sanitization prevents POSIX/WebDAV path splitting corruption
        let slashNamed = DriveItem(
            driveId: "id-slash-1",
            parentId: "root-1",
            name: "Q1/Q2 Report.pdf",
            isFolder: false,
            size: 512
        )
        let sanitized = MetadataStore.disambiguate(item: slashNamed, againstSiblings: children)
        XCTAssertEqual(sanitized.shownAs, "Q1-Q2 Report.pdf")
        try await store.upsertItem(slashNamed)
        let fetchedSlash = try await store.fetchItem(driveId: "id-slash-1")
        XCTAssertEqual(fetchedSlash?.shownAs, "Q1-Q2 Report.pdf")
    }

    func testPosixModeSymlinkPersistenceAndAdditiveMigration() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let dbURL = tempDir.appendingPathComponent("legacy.sqlite")

        // Create a legacy items table without posixMode or symlinkTarget columns
        var rawDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbURL.path, &rawDB, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let legacySQL = """
        CREATE TABLE items (
            driveId TEXT PRIMARY KEY,
            parentId TEXT,
            name TEXT NOT NULL,
            encName TEXT,
            isFolder INTEGER NOT NULL DEFAULT 0,
            size INTEGER NOT NULL DEFAULT 0,
            mime TEXT NOT NULL DEFAULT 'application/octet-stream',
            md5 TEXT,
            version TEXT,
            modifiedTime DOUBLE NOT NULL,
            isEncrypted INTEGER NOT NULL DEFAULT 0,
            pinned INTEGER NOT NULL DEFAULT 0,
            lastOpenedAt DOUBLE,
            trashedAt DOUBLE,
            folded TEXT NOT NULL DEFAULT '',
            shownAs TEXT NOT NULL DEFAULT '',
            tampered INTEGER NOT NULL DEFAULT 0,
            appAuthorized INTEGER NOT NULL DEFAULT 1
        );
        INSERT INTO items (driveId, parentId, name, isFolder, size, modifiedTime, folded, shownAs)
        VALUES ('legacy-1', 'root-1', 'OldNote.txt', 0, 12, 1000.0, 'oldnote.txt', 'OldNote.txt');
        """
        XCTAssertEqual(sqlite3_exec(rawDB, legacySQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close(rawDB)

        // Opening MetadataStore migrates cleanly without losing existing rows
        let store = try MetadataStore(databaseURL: dbURL)
        let legacyRow = try await store.fetchItem(driveId: "legacy-1")
        XCTAssertEqual(legacyRow?.name, "OldNote.txt")
        XCTAssertNil(legacyRow?.posixMode)
        XCTAssertNil(legacyRow?.symlinkTarget)

        // Update posixMode and persist a symlink item
        try await store.updatePosixMode(driveId: "legacy-1", mode: 0o755)
        let fetchedLegacy = try await store.fetchItem(driveId: "legacy-1")
        var syncedLegacy = try XCTUnwrap(fetchedLegacy)
        syncedLegacy.posixMode = nil
        syncedLegacy.size = 99
        try await store.upsertItem(syncedLegacy)

        let afterDelta = try await store.fetchItem(driveId: "legacy-1")
        XCTAssertEqual(afterDelta?.posixMode, 0o755, "Delta upsert without mode must preserve existing posixMode")
        XCTAssertEqual(afterDelta?.size, 99)

        let linkItem = DriveItem(
            driveId: "sym-1",
            parentId: "root-1",
            name: "current",
            isFolder: false,
            size: 11,
            mime: "application/x-symlink",
            posixMode: 0o777,
            symlinkTarget: "../bin/tool"
        )
        try await store.upsertItem(linkItem)
        let fetchedLink = try await store.fetchItem(driveId: "sym-1")
        XCTAssertEqual(fetchedLink?.symlinkTarget, "../bin/tool")
        XCTAssertEqual(fetchedLink?.posixMode, 0o777)
        XCTAssertEqual(fetchedLink?.isSymlink, true)
    }
}

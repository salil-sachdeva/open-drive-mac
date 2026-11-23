import CryptoKit
import XCTest
@testable import OpenDriveCore

final class UploadEngineTests: XCTestCase {
    func testConflictRenameBackoffRetryCancelMeteredPauseAndStreamingEncryption() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let store = try MetadataStore(databaseURL: tempDir.appendingPathComponent("uploads.sqlite"))
        let mockDrive = MockGoogleDrive()
        let uploader = UploadEngine(store: store, client: mockDrive)

        // 1. Optimistic concurrency conflict detection triggers ConflictName copy
        let existingRemote = DriveItem(
            driveId: "doc-remote-1",
            parentId: "root-folder-id",
            name: "Report.txt",
            isFolder: false,
            size: 6,
            md5: "remote-md5-v2",
            version: "2"
        )
        await mockDrive.seedFile(item: existingRemote, data: Data("remote".utf8))

        let conflictLocalURL = tempDir.appendingPathComponent("Report.txt")
        try Data("local edit".utf8).write(to: conflictLocalURL)
        let conflictRec = try await uploader.enqueueUpload(
            localURL: conflictLocalURL,
            parentId: "root-folder-id",
            targetDriveId: "doc-remote-1",
            name: "Report.txt",
            baseVersion: "1",
            baseHash: "old-md5-v1"
        )
        await uploader.processQueue()

        let committedConflict = try await store.fetchUpload(id: conflictRec.id)
        XCTAssertEqual(committedConflict?.state, .done)
        XCTAssertEqual(committedConflict?.renamedLate, true)
        XCTAssertTrue(committedConflict?.name.hasPrefix("Report (conflict from ") == true)
        let remoteOriginal = await mockDrive.contentsById["doc-remote-1"]
        XCTAssertEqual(remoteOriginal, Data("remote".utf8), "Remote file must remain untouched on conflict")

        // 2. Failure backoff (`retryAt` skipped until cleared by `retryUpload`)
        await mockDrive.setSimulatedUploadFailuresRemaining(1)
        let retryURL = tempDir.appendingPathComponent("retry.txt")
        try Data("retry payload".utf8).write(to: retryURL)
        let retryRec = try await uploader.enqueueUpload(
            localURL: retryURL,
            parentId: "root-folder-id",
            targetDriveId: nil,
            name: "retry.txt"
        )
        await uploader.processQueue()

        let failedRec = try await store.fetchUpload(id: retryRec.id)
        XCTAssertEqual(failedRec?.state, .failed)
        XCTAssertNotNil(failedRec?.retryAt)

        // Second pass before retryAt expires must skip the failed item
        await uploader.processQueue()
        let stillFailed = try await store.fetchUpload(id: retryRec.id)
        XCTAssertEqual(stillFailed?.attempts, 1, "Backoff should prevent immediate automatic retry")

        // Manual retry clears retryAt and completes upload
        try await store.retryUpload(id: retryRec.id)
        await uploader.processQueue()
        let retriedDone = try await store.fetchUpload(id: retryRec.id)
        XCTAssertEqual(retriedDone?.state, .done)

        // 3. Metered network auto-pause + resume
        await uploader.setPauseOnMetered(true)
        await uploader.setNetworkState(isMetered: true, isOffline: false)
        let meteredURL = tempDir.appendingPathComponent("metered.txt")
        try Data("metered".utf8).write(to: meteredURL)
        let meteredRec = try await uploader.enqueueUpload(
            localURL: meteredURL,
            parentId: "root-folder-id",
            targetDriveId: nil,
            name: "metered.txt"
        )
        await uploader.processQueue()
        let pausedRec = try await store.fetchUpload(id: meteredRec.id)
        XCTAssertEqual(pausedRec?.state, .paused)
        XCTAssertEqual(pausedRec?.pausedReason, .metered)

        await uploader.setNetworkState(isMetered: false, isOffline: false)
        await uploader.processQueue()
        let resumedDone = try await store.fetchUpload(id: meteredRec.id)
        XCTAssertEqual(resumedDone?.state, .done)

        // 4. Mid-flight cancel deletes upload record cleanly
        let cancelURL = tempDir.appendingPathComponent("cancel.txt")
        try Data("to cancel".utf8).write(to: cancelURL)
        let cancelRec = try await uploader.enqueueUpload(
            localURL: cancelURL,
            parentId: "root-folder-id",
            targetDriveId: nil,
            name: "cancel.txt"
        )
        try await store.requestCancelUpload(id: cancelRec.id)
        await uploader.processQueue()
        let cancelledFetch = try await store.fetchUpload(id: cancelRec.id)
        XCTAssertNil(cancelledFetch)

        // 5. Streaming ODE1 encrypted upload + cleanup + decryption round-trip
        let masterKey = VaultCrypto.generateMasterKey()
        let secretPayload = Data((0..<128_000).map { UInt8($0 % 251) })
        let encURL = tempDir.appendingPathComponent("secret.bin")
        try secretPayload.write(to: encURL)
        let encRec = try await uploader.enqueueUpload(
            localURL: encURL,
            parentId: "root-folder-id",
            targetDriveId: nil,
            name: "secret.bin",
            encrypt: true
        )
        await uploader.processQueue(masterKey: masterKey)

        let encDone = try await store.fetchUpload(id: encRec.id)
        XCTAssertEqual(encDone?.state, .done)
        let driveId = try XCTUnwrap(encDone?.resultDriveId)
        let maybeCiphertext = await mockDrive.contentsById[driveId]
        let uploadedCiphertext = try XCTUnwrap(maybeCiphertext)
        let decrypted = try VaultCrypto.decryptFileData(uploadedCiphertext, masterKey: masterKey)
        XCTAssertEqual(decrypted, secretPayload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: encURL.path + ".ode1"))
    }
}

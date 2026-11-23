import XCTest
@testable import OpenDriveCore

final class ChunkCacheTests: XCTestCase {
    func testLRUEvictionPreservesPinnedAndReconcilesAcrossRestart() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let keyPinned = ChunkKey(driveId: "file-pinned", contentVersion: "v1", index: 0)
        let keyOld = ChunkKey(driveId: "file-old", contentVersion: "v1", index: 0)
        let keyNew = ChunkKey(driveId: "file-new", contentVersion: "v1", index: 0)

        // Cap of 250 bytes: storing three 100-byte chunks forces eviction of the oldest unpinned chunk
        do {
            let cache = try ChunkCache(cacheDirectory: tempDir, maxBytes: 250)
            try await cache.put(Data(repeating: 0xAA, count: 100), for: keyPinned, pinned: true)
            try await cache.put(Data(repeating: 0xBB, count: 100), for: keyOld, pinned: false)
            try await Task.sleep(nanoseconds: 20_000_000)
            try await cache.put(Data(repeating: 0xCC, count: 100), for: keyNew, pinned: false)

            let pinnedPresent = await cache.contains(keyPinned)
            let oldPresent = await cache.contains(keyOld)
            let newPresent = await cache.contains(keyNew)
            let total = await cache.totalBytes

            XCTAssertTrue(pinnedPresent, "Pinned chunk must survive LRU eviction")
            XCTAssertFalse(oldPresent, "Least recently used unpinned chunk must be evicted")
            XCTAssertTrue(newPresent)
            XCTAssertEqual(total, 200)
        }

        // Write an unindexed orphan chunk directly onto disk to verify startup reconciliation & over-budget trimming
        let keyOrphan = ChunkKey(driveId: "file-orphan", contentVersion: "v1", index: 0)
        let orphanURL = tempDir.appendingPathComponent(keyOrphan.cacheFileName)
        try Data(repeating: 0xDD, count: 100).write(to: orphanURL)

        let reopened = try ChunkCache(cacheDirectory: tempDir, maxBytes: 250)
        let reopenedTotal = await reopened.totalBytes
        let pinnedStillThere = await reopened.contains(keyPinned)
        XCTAssertLessThanOrEqual(reopenedTotal, 250)
        XCTAssertTrue(pinnedStillThere, "Pinned chunk metadata from .chunk-index.json must persist across restarts")

        // Verify invalidate(driveId:) removes all chunks for that driveId and updates totalBytes
        await reopened.invalidate(driveId: "file-pinned")
        let afterInvalidatePinned = await reopened.contains(keyPinned)
        let totalAfterInvalidate = await reopened.totalBytes
        XCTAssertFalse(afterInvalidatePinned)
        XCTAssertLessThan(totalAfterInvalidate, reopenedTotal)
    }

    func testHotColdEvictionProtectsRepeatedReadsAndSeedsWriteThroughChunks() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cache = try ChunkCache(cacheDirectory: tempDir, maxBytes: 250)
        let projectKey = ChunkKey(driveId: "project-doc", contentVersion: "v1", index: 0)
        let preview1Key = ChunkKey(driveId: "preview-1", contentVersion: "v1", index: 0)
        let preview2Key = ChunkKey(driveId: "preview-2", contentVersion: "v1", index: 0)

        // Put project chunk oldest, then read it so hitCount becomes 2 (hot)
        try await cache.put(Data(repeating: 0x11, count: 100), for: projectKey)
        _ = await cache.get(projectKey)
        let hotAfterRead = await cache.hotBytes
        XCTAssertEqual(hotAfterRead, 100)

        try await Task.sleep(nanoseconds: 15_000_000)
        try await cache.put(Data(repeating: 0x22, count: 100), for: preview1Key) // cold (hitCount=1)
        try await Task.sleep(nanoseconds: 15_000_000)
        try await cache.put(Data(repeating: 0x33, count: 100), for: preview2Key) // triggers eviction (300 > 250)

        let projectStillCached = await cache.contains(projectKey)
        let preview1Cached = await cache.contains(preview1Key)
        let preview2Cached = await cache.contains(preview2Key)
        XCTAssertTrue(projectStillCached, "Frequently accessed hot chunk must not be evicted before cold previews")
        XCTAssertFalse(preview1Cached, "Oldest cold preview chunk must be evicted first")
        XCTAssertTrue(preview2Cached)

        // Seed write-through chunks from a local scratch file into a larger cache
        let seedDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: seedDir) }
        let seedCache = try ChunkCache(cacheDirectory: seedDir, maxBytes: 1_000)
        let localURL = seedDir.appendingPathComponent("local.bin")
        let localPayload = Data(repeating: 0x5A, count: 250)
        try localPayload.write(to: localURL)

        try await seedCache.seedChunks(
            from: localURL,
            driveId: "uploaded-file",
            contentVersion: "v2",
            chunkSize: 100
        )

        let c0 = await seedCache.get(ChunkKey(driveId: "uploaded-file", contentVersion: "v2", index: 0))
        let c1 = await seedCache.get(ChunkKey(driveId: "uploaded-file", contentVersion: "v2", index: 1))
        let c2 = await seedCache.get(ChunkKey(driveId: "uploaded-file", contentVersion: "v2", index: 2))
        let seededHot = await seedCache.hotBytes
        XCTAssertEqual(c0?.count, 100)
        XCTAssertEqual(c1?.count, 100)
        XCTAssertEqual(c2?.count, 50)
        XCTAssertEqual(seededHot, 250)
    }
}

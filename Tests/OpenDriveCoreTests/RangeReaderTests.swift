import XCTest
@testable import OpenDriveCore

final class RangeReaderTests: XCTestCase {
    func testRangeReaderCoalescingAndSequentialDetection() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cache = try ChunkCache(cacheDirectory: tempDir.appendingPathComponent("chunks"), maxBytes: 10 * 1024 * 1024)
        let mockDrive = MockGoogleDrive()
        let content = Data((0..<4096).map { UInt8($0 % 256) })
        let item = DriveItem(
            driveId: "video-1",
            parentId: "root-folder-id",
            name: "clip.mp4",
            isFolder: false,
            size: Int64(content.count),
            version: "v1"
        )
        await mockDrive.seedFile(item: item, data: content)

        let reader = RangeReader(cache: cache, chunkSize: 1024) { driveId, offset, length in
            try await mockDrive.downloadByteRange(driveId: driveId, offset: offset, length: length)
        }

        let slice = try await reader.readRange(item: item, offset: 500, length: 1000)
        XCTAssertEqual(slice, content.subdata(in: 500..<1500))

        let cachedSlice = try await reader.readRange(item: item, offset: 500, length: 1000)
        XCTAssertEqual(cachedSlice, slice)

        let offsets = await mockDrive.downloadedOffsets
        XCTAssertEqual(offsets.filter { $0 == 0 }.count, 1, "Chunk 0 should only be downloaded once")
        XCTAssertEqual(offsets.filter { $0 == 1024 }.count, 1, "Chunk 1 should only be downloaded once")
    }
}

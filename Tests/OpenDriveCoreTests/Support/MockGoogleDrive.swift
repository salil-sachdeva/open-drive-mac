import Foundation
@testable import OpenDriveCore

/// In-memory `CloudDrive` test double for unit and integration testing.
actor MockGoogleDrive: CloudDrive {
    var filesById: [String: DriveItem] = [:]
    var contentsById: [String: Data] = [:]
    var sessionsByURL: [String: (name: String, parentId: String, targetDriveId: String?, isEncrypted: Bool, buffer: Data)] = [:]
    var downloadCallCount: Int = 0
    var downloadedOffsets: [Int64] = []
    var simulatedChanges: [RemoteChangeEvent] = []

    func seedFile(item: DriveItem, data: Data) {
        filesById[item.driveId] = item
        contentsById[item.driveId] = data
    }

    func fetchUserEmail() async throws -> String {
        "developer@example.com"
    }

    func ensureWorkspace(wholeDrive: Bool) async throws -> (rootId: String, trashId: String?, startPageToken: String) {
        ("root-folder-id", "trash-folder-id", "page-token-1")
    }

    func listChildren(folderId: String) async throws -> [DriveItem] {
        filesById.values.filter { $0.parentId == folderId && $0.trashedAt == nil }
    }

    func fetchItemMetadata(driveId: String) async throws -> DriveItem? {
        filesById[driveId]
    }

    func fetchChanges(pageToken: String) async throws -> RemoteDeltaPage {
        RemoteDeltaPage(events: simulatedChanges, nextPageToken: nil, newStartPageToken: "page-token-2")
    }

    func setSimulatedChanges(_ events: [RemoteChangeEvent]) {
        self.simulatedChanges = events
    }

    func downloadByteRange(driveId: String, offset: Int64, length: Int) async throws -> Data {
        downloadCallCount += 1
        downloadedOffsets.append(offset)
        guard let data = contentsById[driveId] else {
            throw POSIXError(.ENOENT)
        }
        let start = max(0, min(Int(offset), data.count))
        let end = max(start, min(start + length, data.count))
        return data.subdata(in: start..<end)
    }

    func createFolder(name: String, parentId: String, isEncrypted: Bool, origClearName: String?) async throws -> DriveItem {
        let id = "folder-\(UUID().uuidString.prefix(8))"
        let item = DriveItem(
            driveId: id,
            parentId: parentId,
            name: origClearName ?? name,
            encName: isEncrypted ? name : nil,
            isFolder: true,
            size: 0,
            mime: GoogleDriveClient.folderMimeType,
            version: "1",
            isEncrypted: isEncrypted
        )
        filesById[id] = item
        return item
    }

    func renameOrMove(driveId: String, newName: String?, addParentId: String?, removeParentId: String?) async throws -> DriveItem {
        guard var item = filesById[driveId] else {
            throw POSIXError(.ENOENT)
        }
        if let newName {
            item.name = newName
        }
        if let addParentId {
            item.parentId = addParentId
        }
        filesById[driveId] = item
        return item
    }

    func moveToTrash(driveId: String, trashFolderId: String?, currentParentId: String?) async throws {
        filesById.removeValue(forKey: driveId)
        contentsById.removeValue(forKey: driveId)
    }

    func startResumableUpload(
        name: String,
        parentId: String,
        targetDriveId: String?,
        mime: String,
        totalSize: Int64,
        isEncrypted: Bool
    ) async throws -> URL {
        let url = URL(string: "https://upload.example.com/session/\(UUID().uuidString)")!
        sessionsByURL[url.absoluteString] = (name, parentId, targetDriveId, isEncrypted, Data())
        return url
    }

    func uploadResumableChunk(
        sessionURL: URL,
        chunkData: Data,
        offset: Int64,
        totalSize: Int64
    ) async throws -> (nextOffset: Int64, completedItem: DriveItem?) {
        guard var session = sessionsByURL[sessionURL.absoluteString] else {
            throw POSIXError(.EINVAL)
        }
        session.buffer.append(chunkData)
        sessionsByURL[sessionURL.absoluteString] = session
        let nextOffset = Int64(session.buffer.count)

        if nextOffset >= totalSize {
            let id = session.targetDriveId ?? "file-\(UUID().uuidString.prefix(8))"
            let item = DriveItem(
                driveId: id,
                parentId: session.parentId,
                name: session.name,
                encName: session.isEncrypted ? session.name : nil,
                isFolder: false,
                size: totalSize,
                version: "v-\(UUID().uuidString.prefix(4))",
                isEncrypted: session.isEncrypted
            )
            filesById[id] = item
            contentsById[id] = session.buffer
            return (nextOffset, item)
        }
        return (nextOffset, nil)
    }
}

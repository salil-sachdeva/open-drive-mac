import Darwin
import Foundation
import XCTest
@testable import OpenDriveCore

final class LocalWebDAVServerTests: XCTestCase {
    func testClass2WebDAVMethodsChunkedPutExpectContinueAndEphemeralDotfiles() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try MetadataStore(databaseURL: tempDir.appendingPathComponent("dav.sqlite"))
        let cache = try ChunkCache(cacheDirectory: tempDir.appendingPathComponent("chunks"))
        let mockDrive = MockGoogleDrive()
        await mockDrive.setSimulatedQuota(CloudStorageQuota(limit: 500_000_000, usage: 120_000_000))

        let account = CloudAccount(
            id: "gdrive-dav",
            displayName: "My Drive",
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
        await volume.refreshStorageQuotas()

        let server = LocalWebDAVServer(driveVolume: volume)
        let baseURL = try await server.start()
        defer { Task { await server.stop() } }

        let session = URLSession(configuration: .ephemeral)

        // 1. OPTIONS must advertise Class 2 DAV and LOCK/MKCOL/PROPFIND
        var optReq = URLRequest(url: baseURL)
        optReq.httpMethod = "OPTIONS"
        let (_, optRespRaw) = try await session.data(for: optReq)
        let optResp = try XCTUnwrap(optRespRaw as? HTTPURLResponse)
        XCTAssertEqual(optResp.statusCode, 200)
        XCTAssertEqual(optResp.value(forHTTPHeaderField: "DAV"), "1, 2")
        XCTAssertTrue(optResp.value(forHTTPHeaderField: "Allow")?.contains("LOCK") == true)

        // 2. PROPFIND on root returns quota and direct top-level drive entries when 1 account is mounted
        let seedFolder = DriveItem(
            driveId: "seed-folder-1",
            parentId: "root-folder-id",
            name: "Existing Folder",
            isFolder: true
        )
        try await store.upsertItem(seedFolder)
        await mockDrive.seedFile(item: seedFolder, data: Data())

        var propReq = URLRequest(url: baseURL)
        propReq.httpMethod = "PROPFIND"
        propReq.setValue("1", forHTTPHeaderField: "Depth")
        let (propData, propRespRaw) = try await session.data(for: propReq)
        let propResp = try XCTUnwrap(propRespRaw as? HTTPURLResponse)
        XCTAssertEqual(propResp.statusCode, 207)
        let propXML = String(decoding: propData, as: UTF8.self)
        XCTAssertTrue(propXML.contains("/Existing%20Folder/"))
        XCTAssertFalse(propXML.contains("/My%20Drive/"))
        XCTAssertTrue(propXML.contains("<D:quota-available-bytes>380000000</D:quota-available-bytes>"))

        // 2b. Top-level file PUT + DELETE directly at / when 1 account is mounted
        let topFileURL = baseURL.appendingPathComponent("top.txt")
        var topPutReq = URLRequest(url: topFileURL)
        topPutReq.httpMethod = "PUT"
        topPutReq.httpBody = Data("Top-level file".utf8)
        let (_, topPutResp) = try await session.data(for: topPutReq)
        XCTAssertEqual((topPutResp as? HTTPURLResponse)?.statusCode, 201)

        var topDelReq = URLRequest(url: topFileURL)
        topDelReq.httpMethod = "DELETE"
        let (_, topDelResp) = try await session.data(for: topDelReq)
        XCTAssertEqual((topDelResp as? HTTPURLResponse)?.statusCode, 204)

        // 3. MKCOL /Work directly at flattened root
        let workDirURL = baseURL.appendingPathComponent("Work")
        var mkcolReq = URLRequest(url: workDirURL)
        mkcolReq.httpMethod = "MKCOL"
        let (_, mkcolRespRaw) = try await session.data(for: mkcolReq)
        XCTAssertEqual((mkcolRespRaw as? HTTPURLResponse)?.statusCode, 201)

        // 4. PUT /Work/hello.txt + HEAD + GET + Range 206
        let fileURL = workDirURL.appendingPathComponent("hello.txt")
        let payload = Data("Hello WebDAV World!".utf8)
        var putReq = URLRequest(url: fileURL)
        putReq.httpMethod = "PUT"
        putReq.httpBody = payload
        let (_, putRespRaw) = try await session.data(for: putReq)
        XCTAssertEqual((putRespRaw as? HTTPURLResponse)?.statusCode, 201)

        var headReq = URLRequest(url: fileURL)
        headReq.httpMethod = "HEAD"
        let (_, headRespRaw) = try await session.data(for: headReq)
        let headResp = try XCTUnwrap(headRespRaw as? HTTPURLResponse)
        XCTAssertEqual(headResp.statusCode, 200)
        XCTAssertEqual(headResp.value(forHTTPHeaderField: "Content-Length"), "\(payload.count)")

        let (getData, getRespRaw) = try await session.data(from: fileURL)
        XCTAssertEqual((getRespRaw as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(getData, payload)

        var rangeReq = URLRequest(url: fileURL)
        rangeReq.setValue("bytes=6-11", forHTTPHeaderField: "Range")
        let (rangeData, rangeRespRaw) = try await session.data(for: rangeReq)
        let rangeResp = try XCTUnwrap(rangeRespRaw as? HTTPURLResponse)
        XCTAssertEqual(rangeResp.statusCode, 206)
        XCTAssertEqual(rangeData, Data("WebDAV".utf8))
        XCTAssertEqual(rangeResp.value(forHTTPHeaderField: "Content-Range"), "bytes 6-11/\(payload.count)")

        // 5. Raw TCP PUT with Expect: 100-continue and Transfer-Encoding: chunked
        let serverPort = await server.port
        let chunkedResponse = try sendExpectContinueChunkedPut(
            port: serverPort,
            path: "/Work/chunked.txt",
            bodyText: "Chunked Upload OK!"
        )
        XCTAssertTrue(chunkedResponse.contains("HTTP/1.1 100 Continue"))
        XCTAssertTrue(chunkedResponse.contains("HTTP/1.1 201 Created"))

        let (chunkedGetData, _) = try await session.data(from: workDirURL.appendingPathComponent("chunked.txt"))
        XCTAssertEqual(String(decoding: chunkedGetData, as: UTF8.self), "Chunked Upload OK!")

        // 6. LOCK / UNLOCK (Class 2 requirement for read-write mount_webdav)
        var lockReq = URLRequest(url: fileURL)
        lockReq.httpMethod = "LOCK"
        lockReq.httpBody = Data("<D:lockinfo xmlns:D=\"DAV:\"><D:owner><D:href>test</D:href></D:owner></D:lockinfo>".utf8)
        let (lockData, lockRespRaw) = try await session.data(for: lockReq)
        let lockResp = try XCTUnwrap(lockRespRaw as? HTTPURLResponse)
        XCTAssertEqual(lockResp.statusCode, 200)
        let lockToken = try XCTUnwrap(lockResp.value(forHTTPHeaderField: "Lock-Token"))
        XCTAssertTrue(lockToken.contains("opaquelocktoken:"))
        XCTAssertTrue(String(decoding: lockData, as: UTF8.self).contains("<D:lockdiscovery>"))

        var unlockReq = URLRequest(url: fileURL)
        unlockReq.httpMethod = "UNLOCK"
        unlockReq.setValue(lockToken, forHTTPHeaderField: "Lock-Token")
        let (_, unlockRespRaw) = try await session.data(for: unlockReq)
        XCTAssertEqual((unlockRespRaw as? HTTPURLResponse)?.statusCode, 204)

        // 7. MOVE & COPY & DELETE
        let renamedURL = workDirURL.appendingPathComponent("renamed.txt")
        var moveReq = URLRequest(url: fileURL)
        moveReq.httpMethod = "MOVE"
        moveReq.setValue(renamedURL.absoluteString, forHTTPHeaderField: "Destination")
        let (_, moveRespRaw) = try await session.data(for: moveReq)
        XCTAssertEqual((moveRespRaw as? HTTPURLResponse)?.statusCode, 201)

        let copiedURL = workDirURL.appendingPathComponent("copied.txt")
        var copyReq = URLRequest(url: renamedURL)
        copyReq.httpMethod = "COPY"
        copyReq.setValue(copiedURL.absoluteString, forHTTPHeaderField: "Destination")
        let (_, copyRespRaw) = try await session.data(for: copyReq)
        XCTAssertEqual((copyRespRaw as? HTTPURLResponse)?.statusCode, 201)

        var delReq = URLRequest(url: copiedURL)
        delReq.httpMethod = "DELETE"
        let (_, delRespRaw) = try await session.data(for: delReq)
        XCTAssertEqual((delRespRaw as? HTTPURLResponse)?.statusCode, 204)

        // 8. AppleDouble ._ sidecar is handled strictly in-memory and never uploaded to MockGoogleDrive
        let appleDoubleURL = workDirURL.appendingPathComponent("._renamed.txt")
        var dotPut = URLRequest(url: appleDoubleURL)
        dotPut.httpMethod = "PUT"
        dotPut.httpBody = Data([0x00, 0x05, 0x16, 0x07])
        let (_, dotPutResp) = try await session.data(for: dotPut)
        XCTAssertEqual((dotPutResp as? HTTPURLResponse)?.statusCode, 201)

        let (dotGetData, dotGetResp) = try await session.data(from: appleDoubleURL)
        XCTAssertEqual((dotGetResp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(dotGetData, Data([0x00, 0x05, 0x16, 0x07]))

        let uploadedNames = await mockDrive.filesById.values.map(\.name)
        XCTAssertFalse(uploadedNames.contains("._renamed.txt"), "AppleDouble junk must stay out of Google Drive")
        XCTAssertTrue(uploadedNames.contains("renamed.txt"))
        XCTAssertTrue(uploadedNames.contains("chunked.txt"))

        // 9. Registering a second account switches root back to account folders and rejects root PUT
        let workAccount = CloudAccount(
            id: "gdrive-work",
            displayName: "Work Drive",
            rootId: "work-root-folder",
            trashId: "work-trash-folder"
        )
        let workStore = try MetadataStore(databaseURL: tempDir.appendingPathComponent("work.sqlite"))
        try await workStore.upsertAccount(workAccount)
        await volume.registerCloudStack(
            DriveVolume.MountedCloudStack(
                account: workAccount,
                store: workStore,
                client: mockDrive,
                reader: reader,
                uploader: UploadEngine(store: workStore, client: mockDrive),
                syncer: SyncEngine(accountId: workAccount.id, store: workStore, client: mockDrive, cache: cache)
            )
        )

        var multiPropReq = URLRequest(url: baseURL)
        multiPropReq.httpMethod = "PROPFIND"
        multiPropReq.setValue("1", forHTTPHeaderField: "Depth")
        let (multiPropData, multiPropResp) = try await session.data(for: multiPropReq)
        XCTAssertEqual((multiPropResp as? HTTPURLResponse)?.statusCode, 207)
        let multiPropXML = String(decoding: multiPropData, as: UTF8.self)
        XCTAssertTrue(multiPropXML.contains("/My%20Drive/"))
        XCTAssertTrue(multiPropXML.contains("/Work%20Drive/"))

        var blockedPutReq = URLRequest(url: baseURL.appendingPathComponent("blocked.txt"))
        blockedPutReq.httpMethod = "PUT"
        blockedPutReq.httpBody = Data("blocked".utf8)
        let (_, blockedPutResp) = try await session.data(for: blockedPutReq)
        XCTAssertEqual((blockedPutResp as? HTTPURLResponse)?.statusCode, 403)
    }

    func testFileProviderBridgeAuthenticationAndCRUDOperations() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try MetadataStore(databaseURL: tempDir.appendingPathComponent("fp.sqlite"))
        let cache = try ChunkCache(cacheDirectory: tempDir.appendingPathComponent("chunks"))
        let mockDrive = MockGoogleDrive()
        await mockDrive.setSimulatedQuota(CloudStorageQuota(limit: 5_000_000_000_000, usage: 500_000_000_000))
        let account = CloudAccount(
            id: "gdrive-fp",
            displayName: "My Drive",
            rootId: "root-folder-id",
            trashId: "trash-folder-id"
        )
        try await store.upsertAccount(account)

        let existing = DriveItem(
            driveId: "fp-existing",
            parentId: "root-folder-id",
            name: "Existing.txt",
            isFolder: false,
            size: 5,
            version: "v1"
        )
        try await store.upsertItem(existing)
        await mockDrive.seedFile(item: existing, data: Data("hello".utf8))

        let reader = RangeReader(cache: cache) { driveId, offset, length in
            try await mockDrive.downloadByteRange(driveId: driveId, offset: offset, length: length)
        }
        let volume = try DriveVolume(scratchDirectory: tempDir.appendingPathComponent("scratch"))
        await volume.registerCloudStack(
            DriveVolume.MountedCloudStack(
                account: account,
                store: store,
                client: mockDrive,
                reader: reader,
                uploader: UploadEngine(store: store, client: mockDrive),
                syncer: SyncEngine(accountId: account.id, store: store, client: mockDrive, cache: cache)
            )
        )
        await volume.refreshStorageQuotas()

        let server = LocalWebDAVServer(driveVolume: volume)
        let baseURL = try await server.start()
        defer { Task { await server.stop() } }

        let session = URLSession(configuration: .ephemeral)
        let token = server.bridgeAuthToken

        // 1. Unauthorized requests must fail with 401
        let unauthReq = URLRequest(url: baseURL.appendingPathComponent("_od_fp").appendingPathComponent("children"))
        let (_, unauthResp) = try await session.data(for: unauthReq)
        XCTAssertEqual((unauthResp as? HTTPURLResponse)?.statusCode, 401)

        var badTokenReq = unauthReq
        badTokenReq.setValue("Bearer wrong-token", forHTTPHeaderField: "Authorization")
        let (_, badTokenResp) = try await session.data(for: badTokenReq)
        XCTAssertEqual((badTokenResp as? HTTPURLResponse)?.statusCode, 401)

        // 2. Authorized root listing shows direct flattened drive items
        var anchorReq = URLRequest(url: baseURL.appendingPathComponent("_od_fp").appendingPathComponent("anchor"))
        anchorReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (anchorData1, anchorResp1) = try await session.data(for: anchorReq)
        XCTAssertEqual((anchorResp1 as? HTTPURLResponse)?.statusCode, 200)
        let anchorPayload1 = try JSONDecoder().decode([String: String].self, from: anchorData1)
        let initialAnchor = try XCTUnwrap(anchorPayload1["anchor"])
        XCTAssertFalse(initialAnchor.isEmpty)

        var rootItemComps = URLComponents(url: baseURL.appendingPathComponent("_od_fp").appendingPathComponent("item"), resolvingAgainstBaseURL: false)!
        rootItemComps.queryItems = [URLQueryItem(name: "id", value: "root")]
        var rootItemReq = URLRequest(url: rootItemComps.url!)
        rootItemReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (rootItemData, rootItemResp) = try await session.data(for: rootItemReq)
        XCTAssertEqual((rootItemResp as? HTTPURLResponse)?.statusCode, 200)
        let rootItem = try JSONDecoder().decode(DriveVolume.BridgeItem.self, from: rootItemData)
        XCTAssertTrue(rootItem.quotaLabel?.contains("available on Google Drive") == true)

        var listComps = URLComponents(url: baseURL.appendingPathComponent("_od_fp").appendingPathComponent("children"), resolvingAgainstBaseURL: false)!
        listComps.queryItems = [URLQueryItem(name: "parentId", value: "root")]
        var listReq = URLRequest(url: listComps.url!)
        listReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (listData, listResp) = try await session.data(for: listReq)
        XCTAssertEqual((listResp as? HTTPURLResponse)?.statusCode, 200)
        let rootItems = try JSONDecoder().decode([DriveVolume.BridgeItem].self, from: listData)
        XCTAssertEqual(rootItems.map(\.name), ["Existing.txt"])
        XCTAssertEqual(rootItems.first?.parentId, "root")

        // 3. Create folder & file directly under root
        var mkFolderComps = URLComponents(url: baseURL.appendingPathComponent("_od_fp").appendingPathComponent("create"), resolvingAgainstBaseURL: false)!
        mkFolderComps.queryItems = [
            URLQueryItem(name: "parentId", value: "root"),
            URLQueryItem(name: "name", value: "FP Docs"),
            URLQueryItem(name: "isFolder", value: "1")
        ]
        var mkFolderReq = URLRequest(url: mkFolderComps.url!)
        mkFolderReq.httpMethod = "POST"
        mkFolderReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (folderData, folderResp) = try await session.data(for: mkFolderReq)
        XCTAssertEqual((folderResp as? HTTPURLResponse)?.statusCode, 201)
        let folderItem = try JSONDecoder().decode(DriveVolume.BridgeItem.self, from: folderData)
        XCTAssertTrue(folderItem.isFolder)
        XCTAssertEqual(folderItem.parentId, "root")
        XCTAssertTrue(folderItem.quotaLabel?.contains("available on Google Drive") == true)

        var mkFileComps = URLComponents(url: baseURL.appendingPathComponent("_od_fp").appendingPathComponent("create"), resolvingAgainstBaseURL: false)!
        mkFileComps.queryItems = [
            URLQueryItem(name: "parentId", value: folderItem.id),
            URLQueryItem(name: "name", value: "note.txt"),
            URLQueryItem(name: "isFolder", value: "0")
        ]
        var mkFileReq = URLRequest(url: mkFileComps.url!)
        mkFileReq.httpMethod = "POST"
        mkFileReq.httpBody = Data("FileProvider v1".utf8)
        mkFileReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (fileData, fileResp) = try await session.data(for: mkFileReq)
        XCTAssertEqual((fileResp as? HTTPURLResponse)?.statusCode, 201)
        let createdFile = try JSONDecoder().decode(DriveVolume.BridgeItem.self, from: fileData)
        XCTAssertEqual(createdFile.name, "note.txt")
        XCTAssertNil(createdFile.quotaLabel)

        // 4. Read file content
        var contentComps = URLComponents(url: baseURL.appendingPathComponent("_od_fp").appendingPathComponent("content"), resolvingAgainstBaseURL: false)!
        contentComps.queryItems = [URLQueryItem(name: "id", value: createdFile.id)]
        var contentReq = URLRequest(url: contentComps.url!)
        contentReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (fetchedBytes, contentResp) = try await session.data(for: contentReq)
        XCTAssertEqual((contentResp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: fetchedBytes, as: UTF8.self), "FileProvider v1")

        // 5. Modify (rename + overwrite)
        var modComps = URLComponents(url: baseURL.appendingPathComponent("_od_fp").appendingPathComponent("modify"), resolvingAgainstBaseURL: false)!
        modComps.queryItems = [
            URLQueryItem(name: "id", value: createdFile.id),
            URLQueryItem(name: "name", value: "note-v2.txt"),
            URLQueryItem(name: "hasContent", value: "1")
        ]
        var modReq = URLRequest(url: modComps.url!)
        modReq.httpMethod = "POST"
        modReq.httpBody = Data("FileProvider v2 updated".utf8)
        modReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (modData, modResp) = try await session.data(for: modReq)
        XCTAssertEqual((modResp as? HTTPURLResponse)?.statusCode, 200)
        let modifiedFile = try JSONDecoder().decode(DriveVolume.BridgeItem.self, from: modData)
        XCTAssertEqual(modifiedFile.name, "note-v2.txt")

        var contentReq2 = URLRequest(url: contentComps.url!)
        contentReq2.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (fetchedBytes2, _) = try await session.data(for: contentReq2)
        XCTAssertEqual(String(decoding: fetchedBytes2, as: UTF8.self), "FileProvider v2 updated")

        // 6. Delete file & verify 404 on item fetch
        var delComps = URLComponents(url: baseURL.appendingPathComponent("_od_fp").appendingPathComponent("item"), resolvingAgainstBaseURL: false)!
        delComps.queryItems = [URLQueryItem(name: "id", value: createdFile.id)]
        var delReq = URLRequest(url: delComps.url!)
        delReq.httpMethod = "DELETE"
        delReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, delResp) = try await session.data(for: delReq)
        XCTAssertEqual((delResp as? HTTPURLResponse)?.statusCode, 204)

        var itemReq = URLRequest(url: delComps.url!)
        itemReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, missingResp) = try await session.data(for: itemReq)
        XCTAssertEqual((missingResp as? HTTPURLResponse)?.statusCode, 404)

        let (anchorData2, anchorResp2) = try await session.data(for: anchorReq)
        XCTAssertEqual((anchorResp2 as? HTTPURLResponse)?.statusCode, 200)
        let anchorPayload2 = try JSONDecoder().decode([String: String].self, from: anchorData2)
        let updatedAnchor = try XCTUnwrap(anchorPayload2["anchor"])
        XCTAssertNotEqual(updatedAnchor, initialAnchor)
    }

    private func sendExpectContinueChunkedPut(port: UInt16, path: String, bodyText: String) throws -> String {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard res == 0 else { throw POSIXError(.ECONNREFUSED) }

        let headers = "PUT \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nExpect: 100-continue\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        _ = headers.withCString { Darwin.write(fd, $0, strlen($0)) }

        // Wait briefly for 100 Continue
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        _ = Darwin.poll(&pfd, 1, 2000)

        var output = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        let n1 = Darwin.read(fd, &buf, buf.count)
        if n1 > 0 { output.append(buf, count: n1) }

        let hexLen = String(bodyText.utf8.count, radix: 16)
        let chunkedPayload = "\(hexLen)\r\n\(bodyText)\r\n0\r\n\r\n"
        _ = chunkedPayload.withCString { Darwin.write(fd, $0, strlen($0)) }

        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            output.append(buf, count: n)
        }
        return String(decoding: output, as: UTF8.self)
    }
}

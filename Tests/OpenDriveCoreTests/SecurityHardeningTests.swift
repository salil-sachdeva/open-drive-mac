import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import OpenDriveCore

final class SecurityHardeningTests: XCTestCase {
    // MARK: - 1. Zero-Knowledge Vault (No Plaintext Leak + Fail-Closed When Locked)

    func testEncryptedVaultNoPlaintextLeakAndFailsClosedWhenLocked() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try MetadataStore(databaseURL: tempDir.appendingPathComponent("zk.sqlite"))
        let cache = try ChunkCache(cacheDirectory: tempDir.appendingPathComponent("chunks"))
        let mockDrive = MockGoogleDrive()
        let masterKey = VaultCrypto.generateMasterKey()

        let account = CloudAccount(
            id: "zk-acc",
            displayName: "Vault",
            rootId: "root-folder-id",
            trashId: "trash-folder-id",
            encryptionEnabled: true
        )
        try await store.upsertAccount(account)

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
                syncer: SyncEngine(accountId: account.id, store: store, client: mockDrive, cache: cache),
                cache: cache,
                masterKey: masterKey
            )
        )

        // Create encrypted folder & both inline and long-body symlinks
        let folder = try await volume.createItem(
            name: "TopSecretFolder",
            isDirectory: true,
            inDirectory: DriveVolume.rootItemId
        )
        let shortTarget = "../keys/dev.key"
        let shortSym = try await volume.createSymlink(
            name: "short-link",
            target: shortTarget,
            inDirectory: folder.itemId
        )
        let longTarget = String(repeating: "nested/", count: 16) + "vault.key"
        let longSym = try await volume.createSymlink(
            name: "long-link",
            target: longTarget,
            inDirectory: folder.itemId
        )

        // Remote mock storage must NEVER hold plaintext names or plaintext symlink targets
        let remoteItems = await mockDrive.filesById.values
        XCTAssertFalse(remoteItems.contains(where: { $0.name == "TopSecretFolder" }))
        XCTAssertFalse(remoteItems.contains(where: { $0.name == "short-link" }))
        XCTAssertFalse(remoteItems.contains(where: { $0.name == "long-link" }))
        XCTAssertFalse(remoteItems.contains(where: { $0.symlinkTarget == shortTarget }))
        XCTAssertFalse(remoteItems.contains(where: { $0.symlinkTarget == longTarget }))

        if case .remote(_, let shortDriveId) = shortSym.kind,
           let remoteShort = await mockDrive.filesById[shortDriveId],
           let wireSym = remoteShort.symlinkTarget {
            XCTAssertEqual(try VaultCrypto.decryptSymlinkTarget(wireSym, masterKey: masterKey), shortTarget)
        } else {
            XCTFail("Expected remote short symlink")
        }

        if case .remote(_, let longDriveId) = longSym.kind,
           let rawBody = await mockDrive.contentsById[longDriveId],
           let rawBodyStr = String(data: rawBody, encoding: .utf8) {
            XCTAssertNotEqual(rawBodyStr, longTarget)
            XCTAssertEqual(try VaultCrypto.decryptSymlinkTarget(rawBodyStr, masterKey: masterKey), longTarget)
        } else {
            XCTFail("Expected remote long symlink body")
        }

        // Fresh volume re-hydrating from remote mock decrypts both folder name and symlink targets
        let freshStore = try MetadataStore(databaseURL: tempDir.appendingPathComponent("zk-fresh.sqlite"))
        let freshAccount = CloudAccount(
            id: "zk-fresh",
            displayName: "Vault",
            rootId: "root-folder-id",
            trashId: "trash-folder-id",
            encryptionEnabled: true
        )
        try await freshStore.upsertAccount(freshAccount)
        let freshSyncer = SyncEngine(accountId: freshAccount.id, store: freshStore, client: mockDrive, cache: cache)
        _ = try await freshSyncer.hydrateFolderIfNeeded(folderId: "root-folder-id", force: true, masterKey: masterKey)
        let freshVolume = try DriveVolume(scratchDirectory: tempDir.appendingPathComponent("scratch-fresh"))
        await freshVolume.registerCloudStack(
            DriveVolume.MountedCloudStack(
                account: freshAccount,
                store: freshStore,
                client: mockDrive,
                reader: reader,
                uploader: UploadEngine(store: freshStore, client: mockDrive),
                syncer: freshSyncer,
                cache: cache,
                masterKey: masterKey
            )
        )
        let lookedUpFolder = try await freshVolume.lookup(name: "TopSecretFolder", inDirectory: DriveVolume.rootItemId)
        let lookedUpShort = try await freshVolume.lookup(name: "short-link", inDirectory: lookedUpFolder.itemId)
        let lookedUpLong = try await freshVolume.lookup(name: "long-link", inDirectory: lookedUpFolder.itemId)
        let resolvedShortTarget = try await freshVolume.readSymlinkTarget(itemId: lookedUpShort.itemId)
        let resolvedLongTarget = try await freshVolume.readSymlinkTarget(itemId: lookedUpLong.itemId)
        XCTAssertEqual(resolvedShortTarget, shortTarget)
        XCTAssertEqual(resolvedLongTarget, longTarget)

        // Locked encrypted vault (masterKey == nil) must fail closed on mutations
        let lockedVolume = try DriveVolume(scratchDirectory: tempDir.appendingPathComponent("scratch-locked"))
        await lockedVolume.registerCloudStack(
            DriveVolume.MountedCloudStack(
                account: account,
                store: store,
                client: mockDrive,
                reader: reader,
                uploader: UploadEngine(store: store, client: mockDrive),
                syncer: SyncEngine(accountId: account.id, store: store, client: mockDrive, cache: cache),
                cache: cache,
                masterKey: nil
            )
        )
        do {
            _ = try await lockedVolume.createItem(name: "leak.txt", isDirectory: false, inDirectory: DriveVolume.rootItemId)
            XCTFail("Locked encrypted vault must fail closed on file creation")
        } catch let err as POSIXError {
            XCTAssertEqual(err.code, .EACCES)
        }
        do {
            _ = try await lockedVolume.createSymlink(name: "leak-sym", target: "/etc/hosts", inDirectory: DriveVolume.rootItemId)
            XCTFail("Locked encrypted vault must fail closed on symlink creation")
        } catch let err as POSIXError {
            XCTAssertEqual(err.code, .EACCES)
        }
    }

    // MARK: - 2. LocalWebDAVServer (bridgeOnly, DNS Rebinding, Origin, Body Limit, COPY Loop)

    func testWebDAVBridgeOnlyDNSRebindingBodyLimitAndCopyLoopGuard() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try MetadataStore(databaseURL: tempDir.appendingPathComponent("dav-sec.sqlite"))
        let cache = try ChunkCache(cacheDirectory: tempDir.appendingPathComponent("chunks"))
        let mockDrive = MockGoogleDrive()
        let account = CloudAccount(
            id: "dav-sec-acc",
            displayName: "My Drive",
            rootId: "root-folder-id",
            trashId: "trash-folder-id"
        )
        try await store.upsertAccount(account)

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

        let bridgeServer = LocalWebDAVServer(driveVolume: volume, bridgeOnly: true, maxBodyBytes: 64)
        let bridgeURL = try await bridgeServer.start()
        let bridgePort = await bridgeServer.port
        defer { Task { await bridgeServer.stop() } }

        let session = URLSession(configuration: .ephemeral)

        // 1. bridgeOnly rejects WebDAV routes with 403 while serving authenticated bridge routes
        var propReq = URLRequest(url: bridgeURL)
        propReq.httpMethod = "PROPFIND"
        let (_, propResp) = try await session.data(for: propReq)
        XCTAssertEqual((propResp as? HTTPURLResponse)?.statusCode, 403)

        var pingReq = URLRequest(url: bridgeURL.appendingPathComponent("_od_fp").appendingPathComponent("ping"))
        pingReq.setValue("Bearer \(bridgeServer.bridgeAuthToken)", forHTTPHeaderField: "Authorization")
        let (_, pingResp) = try await session.data(for: pingReq)
        XCTAssertEqual((pingResp as? HTTPURLResponse)?.statusCode, 200)

        // 2. Host DNS-rebinding & cross-origin rejection
        let rebindResp = try sendRawHTTP(
            port: bridgePort,
            raw: "GET /_od_fp/ping HTTP/1.1\r\nHost: attacker.example:80\r\nAuthorization: Bearer \(bridgeServer.bridgeAuthToken)\r\nConnection: close\r\n\r\n"
        )
        XCTAssertTrue(rebindResp.starts(with: "HTTP/1.1 403"))

        let originResp = try sendRawHTTP(
            port: bridgePort,
            raw: "GET /_od_fp/ping HTTP/1.1\r\nHost: 127.0.0.1:\(bridgePort)\r\nOrigin: https://attacker.example\r\nAuthorization: Bearer \(bridgeServer.bridgeAuthToken)\r\nConnection: close\r\n\r\n"
        )
        XCTAssertTrue(originResp.starts(with: "HTTP/1.1 403"))

        // 3. Full WebDAV server body size limits & COPY recursion guard
        let davServer = LocalWebDAVServer(driveVolume: volume, bridgeOnly: false, maxBodyBytes: 64)
        let davURL = try await davServer.start()
        let davPort = await davServer.port
        defer { Task { await davServer.stop() } }

        let oversizeResp = try sendRawHTTP(
            port: davPort,
            raw: "PUT /oversize.bin HTTP/1.1\r\nHost: 127.0.0.1:\(davPort)\r\nContent-Length: 128\r\nConnection: close\r\n\r\n"
        )
        XCTAssertTrue(oversizeResp.starts(with: "HTTP/1.1 413"))

        let oversizeChunked = "7f\r\n" + String(repeating: "A", count: 127) + "\r\n0\r\n\r\n"
        let oversizeChunkedResp = try sendRawHTTP(
            port: davPort,
            raw: "PUT /oversize-chunked.bin HTTP/1.1\r\nHost: 127.0.0.1:\(davPort)\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n\(oversizeChunked)"
        )
        XCTAssertTrue(oversizeChunkedResp.starts(with: "HTTP/1.1 413"))

        var mkcolReq = URLRequest(url: davURL.appendingPathComponent("Dir"))
        mkcolReq.httpMethod = "MKCOL"
        let (_, mkcolResp) = try await session.data(for: mkcolReq)
        XCTAssertEqual((mkcolResp as? HTTPURLResponse)?.statusCode, 201)

        var selfCopyReq = URLRequest(url: davURL.appendingPathComponent("Dir"))
        selfCopyReq.httpMethod = "COPY"
        selfCopyReq.setValue(davURL.appendingPathComponent("Dir").appendingPathComponent("Sub").absoluteString, forHTTPHeaderField: "Destination")
        let (_, selfCopyResp) = try await session.data(for: selfCopyReq)
        XCTAssertEqual((selfCopyResp as? HTTPURLResponse)?.statusCode, 403)

        var crossHostCopyReq = URLRequest(url: davURL.appendingPathComponent("Dir"))
        crossHostCopyReq.httpMethod = "COPY"
        crossHostCopyReq.setValue("http://evil.example/Target", forHTTPHeaderField: "Destination")
        let (_, crossHostResp) = try await session.data(for: crossHostCopyReq)
        XCTAssertEqual((crossHostResp as? HTTPURLResponse)?.statusCode, 400)
    }

    // MARK: - 3. LocalNFSServer & XDRWriter Hardening

    func testNFSServerFragmentCapModeStrippingAndTimeOverflow() async throws {
        // XDRWriter timestamp clamping must not trap on extreme doubles
        var xdr = XDRWriter()
        xdr.writeNFSTime(Double.infinity)
        xdr.writeNFSTime(Double.nan)
        xdr.writeNFSTime(-100.5)
        xdr.writeNFSTime(1e14)
        XCTAssertEqual(xdr.data.count, 32)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try MetadataStore(databaseURL: tempDir.appendingPathComponent("nfs-sec.sqlite"))
        let cache = try ChunkCache(cacheDirectory: tempDir.appendingPathComponent("chunks"))
        let mockDrive = MockGoogleDrive()
        let account = CloudAccount(id: "nfs-sec", displayName: "Drive", rootId: "root-folder-id", trashId: "trash-folder-id")
        try await store.upsertAccount(account)

        let volume = try DriveVolume(scratchDirectory: tempDir.appendingPathComponent("scratch"))
        let reader = RangeReader(cache: cache) { id, off, len in
            try await mockDrive.downloadByteRange(driveId: id, offset: off, length: len)
        }
        await volume.registerCloudStack(
            DriveVolume.MountedCloudStack(
                account: account,
                store: store,
                client: mockDrive,
                reader: reader,
                uploader: UploadEngine(store: store, client: mockDrive),
                syncer: SyncEngine(accountId: account.id, store: store, client: mockDrive, cache: cache),
                cache: cache
            )
        )

        // SETATTR 0o6755 strips SUID/SGID to 0o0755
        let created = try await volume.createItem(name: "script.sh", isDirectory: false, inDirectory: DriveVolume.rootItemId)
        let updated = try await volume.setAttributes(itemId: created.itemId, newSize: nil, modifiedTime: nil, posixMode: 0o6755)
        XCTAssertEqual(updated.posixMode, 0o0755)

        let server = LocalNFSServer(driveVolume: volume)
        let port = try await server.start()
        defer { Task { await server.stop() } }

        // Multi-fragment RPC exceeding 32 MiB closes connection cleanly without crashing server
        let fd = try connectLoopback(port: port)
        defer { Darwin.close(fd) }
        // Fragment 1 (not last): 20 MiB header with 0 payload? Wait, write valid 20 MiB mark or small full fragment 1 (20_000_000) wouldn't have bytes unless sent; send two valid 17_000_000 headers would stall waiting body; instead send 16-byte fragment 1 followed immediately by fragment 2 claiming 33 MiB (> 32 MiB limit)
        var evilPayload = Data()
        let frag1Len = UInt32(16).bigEndian
        let frag1Body = Data(repeating: 0, count: 16)
        let frag2OverCap = (0x8000_0000 | UInt32(33 * 1024 * 1024)).bigEndian
        withUnsafeBytes(of: frag1Len) { evilPayload.append(contentsOf: $0) }
        evilPayload.append(frag1Body)
        withUnsafeBytes(of: frag2OverCap) { evilPayload.append(contentsOf: $0) }
        _ = evilPayload.withUnsafeBytes { raw in
            Darwin.write(fd, raw.baseAddress, evilPayload.count)
        }
        var probeBuf = [UInt8](repeating: 0, count: 16)
        let readAfter = Darwin.read(fd, &probeBuf, probeBuf.count)
        XCTAssertEqual(readAfter, 0, "Oversized RPC fragment must close the connection")
    }

    // MARK: - 4. GoogleOAuthLoopbackServer XSS & PKCE State

    func testOAuthLoopbackEscapesErrorHTMLAddsCSPAndUsesHighEntropyState() throws {
        var fds = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer {
            Darwin.close(fds[0])
            Darwin.close(fds[1])
        }

        let pkce = GoogleOAuth.PKCEChallenge()
        XCTAssertEqual(pkce.state.count, 43)
        XCTAssertFalse(pkce.state.contains("="))

        let xssReq = "GET /oauth2callback?error=access_denied&error_description=%3Cscript%3Ealert(1)%3C/script%3E HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        _ = xssReq.withCString { Darwin.write(fds[1], $0, strlen($0)) }

        XCTAssertThrowsError(try GoogleOAuthLoopbackServer.processClientFD(fds[0], expectedState: pkce.state))
        Darwin.shutdown(fds[0], SHUT_WR)

        var respData = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fds[1], &buf, buf.count)
            if n <= 0 { break }
            respData.append(buf, count: n)
        }
        let respStr = String(decoding: respData, as: UTF8.self)
        XCTAssertTrue(respStr.contains("HTTP/1.1 400 Bad Request"))
        XCTAssertTrue(respStr.contains("Content-Security-Policy:"))
        XCTAssertTrue(respStr.contains("X-Content-Type-Options: nosniff"))
        XCTAssertTrue(respStr.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertFalse(respStr.contains("<script>alert(1)</script>"))
    }

    // MARK: - 5. VaultCrypto KDF, File Permissions, Cache Traversal & GoogleDriveClient Validation

    func testKDFBoundsPrivatePermissionsSanitizationAndGoogleClientValidation() throws {
        let (bundle, _, _) = try VaultCrypto.createKeyBundle(passphrase: "correct-horse-battery")

        var badAlg = KeyBundle(
            v: bundle.v,
            kdf: KeyBundle.KDF(alg: "plaintext", ops: bundle.kdf.ops, salt: bundle.kdf.salt),
            mkByPass: bundle.mkByPass,
            mkByRecovery: bundle.mkByRecovery,
            reqPub: bundle.reqPub,
            reqPrivByMK: bundle.reqPrivByMK
        )
        XCTAssertThrowsError(try VaultCrypto.unlockMasterKey(passphrase: "correct-horse-battery", bundle: badAlg)) { err in
            XCTAssertEqual(err as? VaultCryptoError, .invalidKDFParameters)
        }

        badAlg = KeyBundle(
            v: bundle.v,
            kdf: KeyBundle.KDF(alg: "PBKDF2-HMAC-SHA256", ops: 500, salt: bundle.kdf.salt),
            mkByPass: bundle.mkByPass,
            mkByRecovery: bundle.mkByRecovery,
            reqPub: bundle.reqPub,
            reqPrivByMK: bundle.reqPrivByMK
        )
        XCTAssertThrowsError(try VaultCrypto.unlockMasterKey(passphrase: "correct-horse-battery", bundle: badAlg)) { err in
            XCTAssertEqual(err as? VaultCryptoError, .invalidKDFParameters)
        }

        let excessiveOps = KeyBundle(
            v: bundle.v,
            kdf: KeyBundle.KDF(alg: "PBKDF2-HMAC-SHA256", ops: 50_000_000, salt: bundle.kdf.salt),
            mkByPass: bundle.mkByPass,
            mkByRecovery: bundle.mkByRecovery,
            reqPub: bundle.reqPub,
            reqPrivByMK: bundle.reqPrivByMK
        )
        XCTAssertThrowsError(try VaultCrypto.unlockMasterKey(passphrase: "correct-horse-battery", bundle: excessiveOps)) { err in
            XCTAssertEqual(err as? VaultCryptoError, .invalidKDFParameters)
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let pdfURL = tempDir.appendingPathComponent("recovery.pdf")
        try VaultCrypto.exportRecoveryKeyPDF(to: pdfURL, accountName: "Test", email: nil, words: Array(repeating: "abandon", count: 24))
        let pdfPerms = (try FileManager.default.attributesOfItem(atPath: pdfURL.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(pdfPerms.map { $0 & 0o777 }, 0o600)

        let cacheURL = tempDir.appendingPathComponent("private-chunks")
        let cache = try ChunkCache(cacheDirectory: cacheURL)
        _ = cache
        let dirPerms = (try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(dirPerms.map { $0 & 0o777 }, 0o700)

        let traversalKey = ChunkKey(driveId: "../../etc/passwd", contentVersion: "../v1", index: 0)
        XCTAssertFalse(traversalKey.cacheFileName.contains("/"))
        XCTAssertFalse(traversalKey.cacheFileName.contains(".."))
        XCTAssertFalse(traversalKey.cacheFileName.hasPrefix("."))

        XCTAssertEqual(MetadataStore.sanitizeDisplayName("."), "_")
        XCTAssertEqual(MetadataStore.sanitizeDisplayName(".."), "__")
        XCTAssertEqual(MetadataStore.sanitizeDisplayName("ok/name\0"), "ok-name")

        XCTAssertEqual(GoogleDriveClient.escapeQueryLiteral("folder'id\\test\n"), "folder\\'id\\\\test")
        XCTAssertThrowsError(try GoogleDriveClient.validateDriveId("../files/evil"))
        XCTAssertEqual(try GoogleDriveClient.validateDriveId("1Ab_cD-23"), "1Ab_cD-23")

        XCTAssertNoThrow(try GoogleDriveClient.validateResumableUploadURL(URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable")!))
        XCTAssertNoThrow(try GoogleDriveClient.validateResumableUploadURL(URL(string: "https://upload.googleapis.com/upload/session")!))
        XCTAssertThrowsError(try GoogleDriveClient.validateResumableUploadURL(URL(string: "http://www.googleapis.com/upload/session")!))
        XCTAssertThrowsError(try GoogleDriveClient.validateResumableUploadURL(URL(string: "https://attacker.example/upload/session")!))
        XCTAssertThrowsError(try GoogleDriveClient.validateResumableUploadURL(URL(string: "https://user:pass@www.googleapis.com/upload")!))
    }

    // MARK: - Helpers

    private func connectLoopback(port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
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
        guard res == 0 else {
            Darwin.close(fd)
            throw POSIXError(.ECONNREFUSED)
        }
        return fd
    }

    private func sendRawHTTP(port: UInt16, raw: String) throws -> String {
        let fd = try connectLoopback(port: port)
        defer { Darwin.close(fd) }
        _ = raw.withCString { Darwin.write(fd, $0, strlen($0)) }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return String(decoding: out, as: UTF8.self)
    }
}

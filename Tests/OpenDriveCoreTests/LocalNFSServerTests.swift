import Darwin
import Foundation
import XCTest
@testable import OpenDriveCore

final class LocalNFSServerTests: XCTestCase {
    func testMOUNTv3AndNFSv3QuotaStatReadWriteRenameAndEphemeralDotfiles() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try MetadataStore(databaseURL: tempDir.appendingPathComponent("nfs.sqlite"))
        let cache = try ChunkCache(cacheDirectory: tempDir.appendingPathComponent("chunks"))
        let mockDrive = MockGoogleDrive()
        await mockDrive.setSimulatedQuota(CloudStorageQuota(limit: 5_500_000_000_000, usage: 130_000_000_000))

        let account = CloudAccount(
            id: "gdrive-nfs",
            displayName: "My Drive",
            rootId: "root-folder-id",
            trashId: "trash-folder-id"
        )
        try await store.upsertAccount(account)

        let seedFile = DriveItem(
            driveId: "seed-file-1",
            parentId: "root-folder-id",
            name: "Seed.txt",
            isFolder: false,
            size: 4,
            version: "v1"
        )
        try await store.upsertItem(seedFile)
        await mockDrive.seedFile(item: seedFile, data: Data("SEED".utf8))

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
                cache: cache
            )
        )
        await volume.refreshStorageQuotas()

        let server = LocalNFSServer(driveVolume: volume)
        let port = try await server.start()

        let rpc = try NFSBlockingRPCClient(port: port)
        let cleanup: () -> Void = {
            rpc.close()
        }
        defer {
            cleanup()
        }

        // 1. MOUNTv3 NULL & MNT
        let nullMountReply = try rpc.call(program: 100_005, version: 3, procedure: 0, args: Data())
        XCTAssertTrue(nullMountReply.isEmpty)

        var mntArgs = TestXDRWriter()
        mntArgs.writeString("/Open Drive")
        let mntReply = try rpc.call(program: 100_005, version: 3, procedure: 1, args: mntArgs.data)
        var mntReader = TestXDRReader(data: mntReply)
        XCTAssertEqual(try mntReader.readUInt32(), 0) // MNT3_OK
        let rootFH = try mntReader.readOpaque()
        XCTAssertEqual(rootFH.count, 8)
        XCTAssertEqual(Self.decodeUInt64(rootFH), DriveVolume.rootItemId)

        // 2. NFSv3 GETATTR, FSINFO, PATHCONF, and FSSTAT (5.5 TB total / 5.37 TB available)
        let getattrReply = try rpc.call(program: 100_003, version: 3, procedure: 1, args: TestXDRWriter.fhArg(rootFH))
        var gaReader = TestXDRReader(data: getattrReply)
        XCTAssertEqual(try gaReader.readUInt32(), 0)
        XCTAssertEqual(try gaReader.readUInt32(), 2) // NF3DIR

        let fsinfoReply = try rpc.call(program: 100_003, version: 3, procedure: 19, args: TestXDRWriter.fhArg(rootFH))
        var fiReader = TestXDRReader(data: fsinfoReply)
        XCTAssertEqual(try fiReader.readUInt32(), 0)
        try fiReader.skipPostOpAttr()
        XCTAssertEqual(try fiReader.readUInt32(), 131_072) // rtmax

        let pathconfReply = try rpc.call(program: 100_003, version: 3, procedure: 20, args: TestXDRWriter.fhArg(rootFH))
        var pcReader = TestXDRReader(data: pathconfReply)
        XCTAssertEqual(try pcReader.readUInt32(), 0)
        try pcReader.skipPostOpAttr()
        _ = try pcReader.readUInt32() // linkmax
        XCTAssertEqual(try pcReader.readUInt32(), 255) // name_max

        let fsstatReply = try rpc.call(program: 100_003, version: 3, procedure: 18, args: TestXDRWriter.fhArg(rootFH))
        var fsReader = TestXDRReader(data: fsstatReply)
        XCTAssertEqual(try fsReader.readUInt32(), 0)
        try fsReader.skipPostOpAttr()
        XCTAssertEqual(try fsReader.readUInt64(), 5_500_000_000_000)
        XCTAssertEqual(try fsReader.readUInt64(), 5_370_000_000_000)
        XCTAssertEqual(try fsReader.readUInt64(), 5_370_000_000_000)

        // 3. MKDIR /Docs
        var mkdirArgs = TestXDRWriter()
        mkdirArgs.writeOpaque(rootFH)
        mkdirArgs.writeString("Docs")
        mkdirArgs.writeEmptySattr3()
        let mkdirReply = try rpc.call(program: 100_003, version: 3, procedure: 9, args: mkdirArgs.data)
        var mdReader = TestXDRReader(data: mkdirReply)
        XCTAssertEqual(try mdReader.readUInt32(), 0)
        XCTAssertTrue(try mdReader.readUInt32() != 0)
        let docsFH = try mdReader.readOpaque()

        // 4. CREATE Docs/hello.txt + WRITE + COMMIT + READ
        var createArgs = TestXDRWriter()
        createArgs.writeOpaque(docsFH)
        createArgs.writeString("hello.txt")
        createArgs.writeUInt32(1) // GUARDED
        createArgs.writeEmptySattr3()
        let createReply = try rpc.call(program: 100_003, version: 3, procedure: 8, args: createArgs.data)
        var crReader = TestXDRReader(data: createReply)
        XCTAssertEqual(try crReader.readUInt32(), 0)
        XCTAssertTrue(try crReader.readUInt32() != 0)
        let fileFH = try crReader.readOpaque()

        let fileBytes = Data("Hello NFSv3 World!".utf8)
        var writeArgs = TestXDRWriter()
        writeArgs.writeOpaque(fileFH)
        writeArgs.writeUInt64(0)
        writeArgs.writeUInt32(UInt32(fileBytes.count))
        writeArgs.writeUInt32(0) // UNSTABLE
        writeArgs.writeOpaque(fileBytes)
        let writeReply = try rpc.call(program: 100_003, version: 3, procedure: 7, args: writeArgs.data)
        var wrReader = TestXDRReader(data: writeReply)
        XCTAssertEqual(try wrReader.readUInt32(), 0)
        try wrReader.skipWccData()
        XCTAssertEqual(try wrReader.readUInt32(), UInt32(fileBytes.count))

        var commitArgs = TestXDRWriter()
        commitArgs.writeOpaque(fileFH)
        commitArgs.writeUInt64(0)
        commitArgs.writeUInt32(0)
        let commitReply = try rpc.call(program: 100_003, version: 3, procedure: 21, args: commitArgs.data)
        var cmReader = TestXDRReader(data: commitReply)
        XCTAssertEqual(try cmReader.readUInt32(), 0)

        var readArgs = TestXDRWriter()
        readArgs.writeOpaque(fileFH)
        readArgs.writeUInt64(0)
        readArgs.writeUInt32(64)
        let readReply = try rpc.call(program: 100_003, version: 3, procedure: 6, args: readArgs.data)
        var rdReader = TestXDRReader(data: readReply)
        XCTAssertEqual(try rdReader.readUInt32(), 0)
        try rdReader.skipPostOpAttr()
        let readCount = try rdReader.readUInt32()
        let eof = try rdReader.readUInt32() != 0
        let readData = try rdReader.readOpaque()
        XCTAssertEqual(readCount, UInt32(fileBytes.count))
        XCTAssertTrue(eof)
        XCTAssertEqual(readData, fileBytes)

        // 5. READDIRPLUS on root lists Docs and Seed.txt
        var rdpArgs = TestXDRWriter()
        rdpArgs.writeOpaque(rootFH)
        rdpArgs.writeUInt64(0) // cookie
        rdpArgs.writeFixedZeros(8) // cookieverf
        rdpArgs.writeUInt32(8192)
        rdpArgs.writeUInt32(32_768)
        let rdpReply = try rpc.call(program: 100_003, version: 3, procedure: 17, args: rdpArgs.data)
        var rpReader = TestXDRReader(data: rdpReply)
        XCTAssertEqual(try rpReader.readUInt32(), 0)
        try rpReader.skipPostOpAttr()
        try rpReader.skip(8) // cookieverf
        var rootNames: [String] = []
        while (try rpReader.readUInt32()) != 0 {
            _ = try rpReader.readUInt64() // fileid
            rootNames.append(try rpReader.readString())
            _ = try rpReader.readUInt64() // cookie
            try rpReader.skipPostOpAttr()
            if (try rpReader.readUInt32()) != 0 {
                _ = try rpReader.readOpaque()
            }
        }
        XCTAssertTrue(rootNames.contains("Docs"))
        XCTAssertTrue(rootNames.contains("Seed.txt"))

        // 6. RENAME Docs/hello.txt -> Docs/renamed.txt (overwriting an existing target)
        var targetCreateArgs = TestXDRWriter()
        targetCreateArgs.writeOpaque(docsFH)
        targetCreateArgs.writeString("renamed.txt")
        targetCreateArgs.writeUInt32(1)
        targetCreateArgs.writeEmptySattr3()
        let targetCreateReply = try rpc.call(program: 100_003, version: 3, procedure: 8, args: targetCreateArgs.data)
        var tcr = TestXDRReader(data: targetCreateReply)
        XCTAssertEqual(try tcr.readUInt32(), 0)

        var renameArgs = TestXDRWriter()
        renameArgs.writeOpaque(docsFH)
        renameArgs.writeString("hello.txt")
        renameArgs.writeOpaque(docsFH)
        renameArgs.writeString("renamed.txt")
        let renameReply = try rpc.call(program: 100_003, version: 3, procedure: 14, args: renameArgs.data)
        var rnReader = TestXDRReader(data: renameReply)
        XCTAssertEqual(try rnReader.readUInt32(), 0)

        // 7. Ephemeral AppleDouble ._* file stays out of MockGoogleDrive
        var ephCreate = TestXDRWriter()
        ephCreate.writeOpaque(docsFH)
        ephCreate.writeString("._renamed.txt")
        ephCreate.writeUInt32(0) // UNCHECKED
        ephCreate.writeEmptySattr3()
        let ephCreateReply = try rpc.call(program: 100_003, version: 3, procedure: 8, args: ephCreate.data)
        var ecr = TestXDRReader(data: ephCreateReply)
        XCTAssertEqual(try ecr.readUInt32(), 0)
        XCTAssertTrue(try ecr.readUInt32() != 0)
        let ephFH = try ecr.readOpaque()

        let appleDouble = Data([0x00, 0x05, 0x16, 0x07])
        var ephWrite = TestXDRWriter()
        ephWrite.writeOpaque(ephFH)
        ephWrite.writeUInt64(0)
        ephWrite.writeUInt32(UInt32(appleDouble.count))
        ephWrite.writeUInt32(2)
        ephWrite.writeOpaque(appleDouble)
        _ = try rpc.call(program: 100_003, version: 3, procedure: 7, args: ephWrite.data)

        var ephRead = TestXDRWriter()
        ephRead.writeOpaque(ephFH)
        ephRead.writeUInt64(0)
        ephRead.writeUInt32(32)
        let ephReadReply = try rpc.call(program: 100_003, version: 3, procedure: 6, args: ephRead.data)
        var errR = TestXDRReader(data: ephReadReply)
        XCTAssertEqual(try errR.readUInt32(), 0)
        try errR.skipPostOpAttr()
        _ = try errR.readUInt32()
        _ = try errR.readUInt32()
        XCTAssertEqual(try errR.readOpaque(), appleDouble)

        var ephRemove = TestXDRWriter()
        ephRemove.writeOpaque(docsFH)
        ephRemove.writeString("._renamed.txt")
        let ephRmReply = try rpc.call(program: 100_003, version: 3, procedure: 12, args: ephRemove.data)
        XCTAssertEqual(try TestXDRReader.readStatus(ephRmReply), 0)

        let uploadedNames = await mockDrive.filesById.values.map(\.name)
        await volume.waitForBackgroundUploads()
        let uploadedNamesAfterCommit = await mockDrive.filesById.values.map(\.name)
        _ = uploadedNames
        XCTAssertFalse(uploadedNamesAfterCommit.contains("._renamed.txt"))
        XCTAssertTrue(uploadedNamesAfterCommit.contains("renamed.txt"))

        // 8. REMOVE Docs/renamed.txt then RMDIR Docs
        var rmFileArgs = TestXDRWriter()
        rmFileArgs.writeOpaque(docsFH)
        rmFileArgs.writeString("renamed.txt")
        let rmFileReply = try rpc.call(program: 100_003, version: 3, procedure: 12, args: rmFileArgs.data)
        XCTAssertEqual(try TestXDRReader.readStatus(rmFileReply), 0)

        var rmDirArgs = TestXDRWriter()
        rmDirArgs.writeOpaque(rootFH)
        rmDirArgs.writeString("Docs")
        let rmDirReply = try rpc.call(program: 100_003, version: 3, procedure: 13, args: rmDirArgs.data)
        XCTAssertEqual(try TestXDRReader.readStatus(rmDirReply), 0)

        await server.stop()
    }

    func testLocalMDNSRegistrarResolvesLoopbackQuickly() {
        let registrar = LocalMDNSRegistrar(hostname: "Open-Drive-UnitTest.local")
        defer { registrar.stop() }

        let resolved = registrar.startAndResolve(timeoutSeconds: 2.0)
        XCTAssertEqual(resolved, "Open-Drive-UnitTest.local")

        registrar.stop()
    }

    func testRFC6761LoopbackHostnameResolution() {
        XCTAssertEqual(
            LocalMDNSRegistrar.resolveLoopbackHostname(preferred: "Open-Drive.localhost"),
            "Open-Drive.localhost"
        )
    }

    func testNFSv3SymlinkReadlinkChmodZeroBytesOnDiskAndWarmReadback() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try MetadataStore(databaseURL: tempDir.appendingPathComponent("nfs-parity.sqlite"))
        let cache = try ChunkCache(cacheDirectory: tempDir.appendingPathComponent("chunks"))
        let mockDrive = MockGoogleDrive()

        let account = CloudAccount(
            id: "gdrive-parity",
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
                syncer: SyncEngine(accountId: account.id, store: store, client: mockDrive, cache: cache),
                cache: cache
            )
        )

        let server = LocalNFSServer(driveVolume: volume)
        let port = try await server.start()
        let rpc = try NFSBlockingRPCClient(port: port)
        defer { rpc.close() }

        // 1. Mount root
        var mntArgs = TestXDRWriter()
        mntArgs.writeString("/Open Drive")
        let mntReply = try rpc.call(program: 100_005, version: 3, procedure: 1, args: mntArgs.data)
        var mntReader = TestXDRReader(data: mntReply)
        XCTAssertEqual(try mntReader.readUInt32(), 0)
        let rootFH = try mntReader.readOpaque()

        // 2. CREATE run.sh -> WRITE -> chmod +x (SETATTR 0o755) -> non-blocking COMMIT
        var createArgs = TestXDRWriter()
        createArgs.writeOpaque(rootFH)
        createArgs.writeString("run.sh")
        createArgs.writeUInt32(1) // GUARDED
        createArgs.writeEmptySattr3()
        let createReply = try rpc.call(program: 100_003, version: 3, procedure: 8, args: createArgs.data)
        var crReader = TestXDRReader(data: createReply)
        XCTAssertEqual(try crReader.readUInt32(), 0)
        XCTAssertTrue(try crReader.readUInt32() != 0)
        let scriptFH = try crReader.readOpaque()

        let scriptBytes = Data("#!/bin/sh\necho open-drive\n".utf8)
        var writeArgs = TestXDRWriter()
        writeArgs.writeOpaque(scriptFH)
        writeArgs.writeUInt64(0)
        writeArgs.writeUInt32(UInt32(scriptBytes.count))
        writeArgs.writeUInt32(0)
        writeArgs.writeOpaque(scriptBytes)
        let writeReply = try rpc.call(program: 100_003, version: 3, procedure: 7, args: writeArgs.data)
        XCTAssertEqual(try TestXDRReader.readStatus(writeReply), 0)

        var chmodArgs = TestXDRWriter()
        chmodArgs.writeOpaque(scriptFH)
        chmodArgs.writeModeOnlySattr3(0o755)
        chmodArgs.writeUInt32(0) // guard false
        let chmodReply = try rpc.call(program: 100_003, version: 3, procedure: 2, args: chmodArgs.data)
        XCTAssertEqual(try TestXDRReader.readStatus(chmodReply), 0)

        var commitArgs = TestXDRWriter()
        commitArgs.writeOpaque(scriptFH)
        commitArgs.writeUInt64(0)
        commitArgs.writeUInt32(0)
        let commitReply = try rpc.call(program: 100_003, version: 3, procedure: 21, args: commitArgs.data)
        XCTAssertEqual(try TestXDRReader.readStatus(commitReply), 0)

        // Wait for background upload + ChunkCache seeding + mode sync
        await volume.waitForBackgroundUploads()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Verify GETATTR reports size == logicalSize, used == 0 (zero bytes on disk), and mode 0o755
        let gaReply = try rpc.call(program: 100_003, version: 3, procedure: 1, args: TestXDRWriter.fhArg(scriptFH))
        var ga = TestXDRReader(data: gaReply)
        XCTAssertEqual(try ga.readUInt32(), 0)
        let attrs = try ga.readFattr3()
        XCTAssertEqual(attrs.type, 1) // NF3REG
        XCTAssertEqual(attrs.mode, 0o755)
        XCTAssertEqual(attrs.size, UInt64(scriptBytes.count))
        XCTAssertEqual(attrs.used, 0, "Remote cloud files must report zero bytes allocated on disk")

        let remoteScript = await mockDrive.filesById.values.first(where: { $0.name == "run.sh" })
        XCTAssertEqual(remoteScript?.posixMode, 0o755)

        // 3. Re-reading freshly written file must be served from seeded ChunkCache (0 remote downloads)
        var readArgs = TestXDRWriter()
        readArgs.writeOpaque(scriptFH)
        readArgs.writeUInt64(0)
        readArgs.writeUInt32(128)
        let readReply = try rpc.call(program: 100_003, version: 3, procedure: 6, args: readArgs.data)
        var rd = TestXDRReader(data: readReply)
        XCTAssertEqual(try rd.readUInt32(), 0)
        try rd.skipPostOpAttr()
        _ = try rd.readUInt32()
        _ = try rd.readUInt32()
        XCTAssertEqual(try rd.readOpaque(), scriptBytes)
        let downloads = await mockDrive.downloadCallCount
        XCTAssertEqual(downloads, 0, "Freshly uploaded file should read from ChunkCache without re-downloading")

        // 4. SYMLINK + READLINK + GETATTR (type 5, mode 0o777)
        var symArgs = TestXDRWriter()
        symArgs.writeOpaque(rootFH)
        symArgs.writeString("run-link.sh")
        symArgs.writeEmptySattr3()
        symArgs.writeString("run.sh")
        let symReply = try rpc.call(program: 100_003, version: 3, procedure: 10, args: symArgs.data)
        var sr = TestXDRReader(data: symReply)
        XCTAssertEqual(try sr.readUInt32(), 0)
        XCTAssertTrue(try sr.readUInt32() != 0)
        let symFH = try sr.readOpaque()
        XCTAssertTrue(try sr.readUInt32() != 0)
        let symAttrs = try sr.readFattr3()
        XCTAssertEqual(symAttrs.type, 5) // NF3LNK
        XCTAssertEqual(symAttrs.mode, 0o777)
        XCTAssertEqual(symAttrs.used, 0)

        let rlReply = try rpc.call(program: 100_003, version: 3, procedure: 5, args: TestXDRWriter.fhArg(symFH))
        var rlr = TestXDRReader(data: rlReply)
        XCTAssertEqual(try rlr.readUInt32(), 0)
        try rlr.skipPostOpAttr()
        XCTAssertEqual(try rlr.readString(), "run.sh")

        await server.stop()
    }

    func testMOUNTv3CustomExportPath() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let volume = try DriveVolume(scratchDirectory: tempDir.appendingPathComponent("scratch"), rootName: "My Cloud")
        let server = LocalNFSServer(driveVolume: volume, exportPath: "/My Cloud")
        let port = try await server.start()
        let rpc = try NFSBlockingRPCClient(port: port)
        defer { rpc.close() }

        let exportReply = try rpc.call(program: 100_005, version: 3, procedure: 5, args: Data())
        var expReader = TestXDRReader(data: exportReply)
        XCTAssertEqual(try expReader.readUInt32(), 1) // value_follows = true
        XCTAssertEqual(try expReader.readString(), "/My Cloud")

        var mntArgs = TestXDRWriter()
        mntArgs.writeString("/My Cloud")
        let mntReply = try rpc.call(program: 100_005, version: 3, procedure: 1, args: mntArgs.data)
        var mntReader = TestXDRReader(data: mntReply)
        XCTAssertEqual(try mntReader.readUInt32(), 0)
        XCTAssertEqual(Self.decodeUInt64(try mntReader.readOpaque()), DriveVolume.rootItemId)

        await server.stop()
    }

    private static func decodeUInt64(_ data: Data) -> UInt64 {
        var val: UInt64 = 0
        for b in data {
            val = (val << 8) | UInt64(b)
        }
        return val
    }
}

// MARK: - Test-Only Blocking TCP RPC Client & Minimal XDR Helpers

private final class NFSBlockingRPCClient {
    private let fd: Int32
    private var nextXID: UInt32 = 1

    init(port: UInt16) throws {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard sock >= 0 else { throw POSIXError(.EBADF) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard res == 0 else {
            Darwin.close(sock)
            throw POSIXError(.ECONNREFUSED)
        }
        self.fd = sock
    }

    func close() {
        Darwin.close(fd)
    }

    func call(program: UInt32, version: UInt32, procedure: UInt32, args: Data) throws -> Data {
        let xid = nextXID
        nextXID += 1

        var call = TestXDRWriter()
        call.writeUInt32(0) // placeholder for record mark
        call.writeUInt32(xid)
        call.writeUInt32(0) // CALL
        call.writeUInt32(2) // RPC v2
        call.writeUInt32(program)
        call.writeUInt32(version)
        call.writeUInt32(procedure)
        call.writeUInt32(0) // cred AUTH_NONE
        call.writeUInt32(0)
        call.writeUInt32(0) // verf AUTH_NONE
        call.writeUInt32(0)
        call.data.append(args)

        var mark = (0x8000_0000 | UInt32(call.data.count - 4)).bigEndian
        call.data.replaceSubrange(0..<4, with: withUnsafeBytes(of: &mark) { Data($0) })

        try writeAll(call.data)

        var assembled = Data()
        while true {
            let hdr = try readExact(4)
            let rm = (UInt32(hdr[0]) << 24) | (UInt32(hdr[1]) << 16) | (UInt32(hdr[2]) << 8) | UInt32(hdr[3])
            let isLast = (rm & 0x8000_0000) != 0
            let fragLen = Int(rm & 0x7FFF_FFFF)
            if fragLen > 0 {
                assembled.append(try readExact(fragLen))
            }
            if isLast { break }
        }

        var reader = TestXDRReader(data: assembled)
        XCTAssertEqual(try reader.readUInt32(), xid)
        XCTAssertEqual(try reader.readUInt32(), 1) // REPLY
        XCTAssertEqual(try reader.readUInt32(), 0) // MSG_ACCEPTED
        _ = try reader.readUInt32() // verf flavor
        _ = try reader.readOpaque() // verf
        XCTAssertEqual(try reader.readUInt32(), 0) // SUCCESS
        return Data(assembled[reader.offset...])
    }

    private func writeAll(_ data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while sent < data.count {
                let n = Darwin.write(fd, base.advanced(by: sent), data.count - sent)
                if n <= 0 { throw POSIXError(.EIO) }
                sent += n
            }
        }
    }

    private func readExact(_ count: Int) throws -> Data {
        var result = Data(count: count)
        var received = 0
        try result.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while received < count {
                let n = Darwin.read(fd, base.advanced(by: received), count - received)
                if n <= 0 { throw POSIXError(.ECONNRESET) }
                received += n
            }
        }
        return result
    }
}

private struct TestXDRWriter {
    var data = Data()

    static func fhArg(_ fh: Data) -> Data {
        var w = TestXDRWriter()
        w.writeOpaque(fh)
        return w.data
    }

    mutating func writeUInt32(_ value: UInt32) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    mutating func writeUInt64(_ value: UInt64) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    mutating func writeOpaque(_ bytes: Data) {
        writeUInt32(UInt32(bytes.count))
        data.append(bytes)
        let rem = bytes.count & 3
        if rem != 0 {
            data.append(contentsOf: repeatElement(UInt8(0), count: 4 - rem))
        }
    }

    mutating func writeString(_ str: String) {
        writeOpaque(Data(str.utf8))
    }

    mutating func writeFixedZeros(_ count: Int) {
        data.append(Data(repeating: 0, count: count))
    }

    mutating func writeEmptySattr3() {
        writeUInt32(0) // mode
        writeUInt32(0) // uid
        writeUInt32(0) // gid
        writeUInt32(0) // size
        writeUInt32(0) // atime
        writeUInt32(0) // mtime
    }

    mutating func writeModeOnlySattr3(_ mode: UInt32) {
        writeUInt32(1) // set mode
        writeUInt32(mode)
        writeUInt32(0) // uid
        writeUInt32(0) // gid
        writeUInt32(0) // size
        writeUInt32(0) // atime
        writeUInt32(0) // mtime
    }
}

private struct TestXDRReader {
    let data: Data
    var offset = 0

    static func readStatus(_ data: Data) throws -> UInt32 {
        var r = TestXDRReader(data: data)
        return try r.readUInt32()
    }

    mutating func skip(_ count: Int) throws {
        guard offset + count <= data.count else { throw POSIXError(.EINVAL) }
        offset += count
    }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw POSIXError(.EINVAL) }
        let s = data.startIndex + offset
        let val = (UInt32(data[s]) << 24) | (UInt32(data[s + 1]) << 16) | (UInt32(data[s + 2]) << 8) | UInt32(data[s + 3])
        offset += 4
        return val
    }

    mutating func readUInt64() throws -> UInt64 {
        (UInt64(try readUInt32()) << 32) | UInt64(try readUInt32())
    }

    mutating func readOpaque() throws -> Data {
        let len = Int(try readUInt32())
        let padded = (len + 3) & ~3
        guard offset + padded <= data.count else { throw POSIXError(.EINVAL) }
        let out = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + len))
        offset += padded
        return out
    }

    mutating func readString() throws -> String {
        let raw = try readOpaque()
        return String(decoding: raw, as: UTF8.self)
    }

    mutating func readFattr3() throws -> (type: UInt32, mode: UInt32, size: UInt64, used: UInt64) {
        let type = try readUInt32()
        let mode = try readUInt32()
        _ = try readUInt32() // nlink
        _ = try readUInt32() // uid
        _ = try readUInt32() // gid
        let size = try readUInt64()
        let used = try readUInt64()
        try skip(48) // rdev(8) + fsid(8) + fileid(8) + atime(8) + mtime(8) + ctime(8)
        return (type, mode, size, used)
    }

    mutating func skipPostOpAttr() throws {
        if (try readUInt32()) != 0 {
            try skip(84)
        }
    }

    mutating func skipWccData() throws {
        if (try readUInt32()) != 0 {
            try skip(24) // size + mtime + ctime
        }
        try skipPostOpAttr()
    }
}

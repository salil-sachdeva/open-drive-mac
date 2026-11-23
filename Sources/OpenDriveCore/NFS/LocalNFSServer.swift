import Darwin
import Foundation
import Network

/// Serializes outbound RPC record writes on a single TCP connection so concurrent
/// request handlers never interleave bytes on the wire.
private actor NFSConnectionWriter {
    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    func send(_ data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }
}

/// Pure-Swift loopback RFC 1813 NFSv3 + MOUNTv3 server backed by `DriveVolume`.
/// Exposes Google Drive's live cloud storage quota via `FSSTAT` and mounts without `sudo`
/// or kernel extensions via `/sbin/mount_nfs`.
public actor LocalNFSServer {
    private struct EphemeralNode: Sendable {
        let inode: UInt64
        var parentInode: UInt64
        var name: String
        var isDirectory: Bool
        var mode: UInt32
        var symlinkTarget: String? = nil
        var data: Data
        var modifiedTime: Double
    }

    private struct DirectoryEntry: Sendable {
        let inode: UInt64
        let name: String
        let attrs: NFSAttributes
        let cookie: UInt64
    }

    private static let ephemeralInodeStart: UInt64 = 0x8000_0000_0000_0001
    private static let maxConnections = 64
    private static let maxRPCMessageBytes = 32 * 1024 * 1024
    private static let maxRPCFragmentsPerMessage = 1024
    private static let maxEphemeralNodes = 1024
    private static let maxEphemeralNodeBytes = 8 * 1024 * 1024
    private static let maxEphemeralTotalBytes = 32 * 1024 * 1024
    private static let maxExclusiveVerifiers = 1024
    private static let ephemeralPrefixNames: Set<String> = [
        ".DS_Store",
        ".localized",
        ".metadata_never_index",
        ".Spotlight-V100",
        ".fseventsd",
        ".Trashes",
        ".TemporaryItems",
        ".VolumeIcon.icns",
        ".hidden"
    ]

    let driveVolume: DriveVolume
    public let exportPath: String

    private var listener: NWListener?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private var ephemeralNodes: [UInt64: EphemeralNode] = [:]
    private var nextEphemeralInode: UInt64 = LocalNFSServer.ephemeralInodeStart
    private var exclusiveCreateVerifiers: [String: Data] = [:]
    private var pendingCommitTasks: [UInt64: Task<Void, Never>] = [:]
    private var inFlightCommits: [UInt64: Task<Void, Error>] = [:]
    private var isStopped = false

    private let uid: UInt32
    private let gid: UInt32
    private let writeVerifier: Data

    public private(set) var port: UInt16 = 0

    public init(driveVolume: DriveVolume, exportPath: String = "/Open Drive") {
        self.driveVolume = driveVolume
        self.exportPath = exportPath.hasPrefix("/") ? exportPath : "/\(exportPath)"
        self.uid = Darwin.getuid()
        self.gid = Darwin.getgid()
        var bootTag = UInt64(Date().timeIntervalSince1970 * 1_000_000).bigEndian
        self.writeVerifier = withUnsafeBytes(of: &bootTag) { Data($0) }
    }

    /// Starts the loopback TCP listener on `127.0.0.1` and returns the bound port.
    @discardableResult
    public func start() async throws -> UInt16 {
        if port != 0, listener != nil {
            return port
        }
        isStopped = false

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true

        let newListener = try NWListener(using: parameters)
        self.listener = newListener

        let boundPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            final class ResumeBox: @unchecked Sendable {
                let lock = NSLock()
                var resumed = false
            }
            let box = ResumeBox()

            newListener.stateUpdateHandler = { state in
                box.lock.withLock {
                    guard !box.resumed else { return }
                    switch state {
                    case .ready:
                        box.resumed = true
                        let actualPort = newListener.port?.rawValue ?? 0
                        continuation.resume(returning: actualPort)
                    case .failed(let error):
                        box.resumed = true
                        continuation.resume(throwing: error)
                    case .cancelled:
                        box.resumed = true
                        continuation.resume(throwing: POSIXError(.ECANCELED))
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                Task { await self?.acceptConnection(connection) }
            }
            newListener.start(queue: DispatchQueue(label: "org.opendrive.nfs.listener"))
        }

        self.port = boundPort
        return boundPort
    }

    /// Flushes pending dirty writes and shuts down active sockets and listener.
    public func stop() async {
        isStopped = true
        let pendingIds = Array(pendingCommitTasks.keys)
        for (_, task) in pendingCommitTasks {
            task.cancel()
        }
        pendingCommitTasks.removeAll()

        for id in pendingIds {
            _ = try? await driveVolume.closeAndCommitIfDirty(itemId: id)
        }
        for (_, inFlight) in inFlightCommits {
            _ = try? await inFlight.value
        }
        inFlightCommits.removeAll()

        listener?.cancel()
        listener = nil
        port = 0

        for conn in activeConnections.values {
            conn.cancel()
        }
        activeConnections.removeAll()
        ephemeralNodes.removeAll()
        exclusiveCreateVerifiers.removeAll()
    }

    // MARK: - Connection Loop & RFC 5531 Record Framing

    private func acceptConnection(_ connection: NWConnection) {
        guard !isStopped, activeConnections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let connId = ObjectIdentifier(connection)
        activeConnections[connId] = connection

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { await self?.removeConnection(connId) }
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "org.opendrive.nfs.conn.\(connId.hashValue)"))

        Task { [weak self] in
            await self?.serveConnection(connection, connId: connId)
        }
    }

    private func removeConnection(_ connId: ObjectIdentifier) {
        activeConnections.removeValue(forKey: connId)
    }

    private func serveConnection(_ connection: NWConnection, connId: ObjectIdentifier) async {
        let writer = NFSConnectionWriter(connection: connection)
        defer {
            connection.cancel()
            activeConnections.removeValue(forKey: connId)
        }

        var tcpBuffer = Data()
        var currentMessage = Data()
        var fragmentCount = 0

        while !isStopped {
            guard tcpBuffer.count >= 4 else {
                guard let chunk = await receiveChunk(from: connection), !chunk.isEmpty else {
                    return
                }
                tcpBuffer.append(chunk)
                if tcpBuffer.count > Self.maxRPCMessageBytes + 4 {
                    return
                }
                continue
            }

            let mark = tcpBuffer.withUnsafeBytes { raw -> UInt32 in
                let b0 = UInt32(raw[0]) << 24
                let b1 = UInt32(raw[1]) << 16
                let b2 = UInt32(raw[2]) << 8
                let b3 = UInt32(raw[3])
                return b0 | b1 | b2 | b3
            }
            let isLastFragment = (mark & 0x8000_0000) != 0
            let fragmentLength = Int(mark & 0x7FFF_FFFF)

            guard fragmentLength <= Self.maxRPCMessageBytes,
                  fragmentCount < Self.maxRPCFragmentsPerMessage,
                  currentMessage.count <= Self.maxRPCMessageBytes - fragmentLength else {
                return
            }

            let totalNeeded = 4 + fragmentLength
            while tcpBuffer.count < totalNeeded {
                guard let chunk = await receiveChunk(from: connection), !chunk.isEmpty else {
                    return
                }
                tcpBuffer.append(chunk)
                if tcpBuffer.count > Self.maxRPCMessageBytes + 4 {
                    return
                }
            }

            fragmentCount += 1
            if fragmentLength > 0 {
                let fragStart = tcpBuffer.startIndex + 4
                currentMessage.append(tcpBuffer[fragStart..<(fragStart + fragmentLength)])
            }
            tcpBuffer.removeFirst(totalNeeded)

            if isLastFragment {
                let message = currentMessage
                currentMessage.removeAll(keepingCapacity: true)
                fragmentCount = 0
                Task { [weak self] in
                    await self?.processRPCMessage(message, writer: writer)
                }
            }
        }
    }

    private func receiveChunk(from connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { data, _, isComplete, error in
                if error != nil {
                    continuation.resume(returning: nil)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Data())
            }
        }
    }

    // MARK: - RPC Dispatch

    private func processRPCMessage(_ message: Data, writer: NFSConnectionWriter) async {
        var reader = XDRReader(data: message)
        let header: RPCCallHeader
        do {
            header = try reader.readRPCCallHeader()
        } catch {
            return
        }

        let reply: Data
        switch header.program {
        case RPCProgram.mount:
            reply = handleMountProcedure(header: header, reader: &reader)
        case RPCProgram.nfs:
            reply = await handleNFSProcedure(header: header, reader: &reader)
        default:
            reply = XDRWriter.acceptedReply(xid: header.xid, acceptStatus: 1) // PROG_UNAVAIL
        }
        await writer.send(reply)
    }

    // MARK: - MOUNTv3 (100005)

    private func handleMountProcedure(header: RPCCallHeader, reader: inout XDRReader) -> Data {
        guard let proc = MOUNTv3Procedure(rawValue: header.procedure) else {
            return XDRWriter.acceptedReply(xid: header.xid, acceptStatus: 3) // PROC_UNAVAIL
        }
        var out = XDRWriter()
        switch proc {
        case .null, .umnt, .umntAll:
            return XDRWriter.acceptedReply(xid: header.xid)
        case .mnt:
            out.writeUInt32(0) // MNT3_OK
            out.writeFileHandle(DriveVolume.rootItemId)
            out.writeUInt32(2) // auth flavor count
            out.writeUInt32(0) // AUTH_NONE
            out.writeUInt32(1) // AUTH_SYS
            return XDRWriter.acceptedReply(xid: header.xid, body: out.data)
        case .dump:
            out.writeBool(false)
            return XDRWriter.acceptedReply(xid: header.xid, body: out.data)
        case .export:
            out.writeBool(true)
            out.writeString(exportPath)
            out.writeBool(false) // groups end
            out.writeBool(false) // exports end
            return XDRWriter.acceptedReply(xid: header.xid, body: out.data)
        }
    }

    // MARK: - NFSv3 (100003)

    private func handleNFSProcedure(header: RPCCallHeader, reader: inout XDRReader) async -> Data {
        guard let proc = NFSv3Procedure(rawValue: header.procedure) else {
            return XDRWriter.acceptedReply(xid: header.xid, acceptStatus: 3) // PROC_UNAVAIL
        }

        do {
            switch proc {
            case .null:
                return XDRWriter.acceptedReply(xid: header.xid)

            case .getattr:
                let inode = try reader.readFileHandleInode()
                return XDRWriter.acceptedReply(xid: header.xid, body: await handleGetAttr(inode: inode))

            case .setattr:
                let inode = try reader.readFileHandleInode()
                let sattr = try readSetAttr3(&reader)
                let checkGuard = try reader.readBool()
                if checkGuard {
                    _ = try reader.readUInt32()
                    _ = try reader.readUInt32()
                }
                return XDRWriter.acceptedReply(
                    xid: header.xid,
                    body: await handleSetAttr(
                        inode: inode,
                        mode: sattr.mode,
                        newSize: sattr.size,
                        modifiedTime: sattr.modifiedTime
                    )
                )

            case .lookup:
                let dirInode = try reader.readFileHandleInode()
                let name = try reader.readString()
                return XDRWriter.acceptedReply(
                    xid: header.xid,
                    body: await handleLookup(dirInode: dirInode, name: name)
                )

            case .access:
                let inode = try reader.readFileHandleInode()
                let requestedAccess = try reader.readUInt32()
                return XDRWriter.acceptedReply(
                    xid: header.xid,
                    body: await handleAccess(inode: inode, requested: requestedAccess)
                )

            case .readlink:
                let inode = try reader.readFileHandleInode()
                return XDRWriter.acceptedReply(
                    xid: header.xid,
                    body: await handleReadlink(inode: inode)
                )

            case .read:
                let inode = try reader.readFileHandleInode()
                let offset = try reader.readUInt64()
                let count = try reader.readUInt32()
                return XDRWriter.acceptedReply(
                    xid: header.xid,
                    body: await handleRead(inode: inode, offset: offset, count: count)
                )

            case .write:
                let inode = try reader.readFileHandleInode()
                let offset = try reader.readUInt64()
                let count = try reader.readUInt32()
                let stable = try reader.readUInt32()
                let payload = try reader.readOpaque()
                let slice = payload.count > Int(count) ? Data(payload.prefix(Int(count))) : payload
                return XDRWriter.acceptedReply(
                    xid: header.xid,
                    body: await handleWrite(inode: inode, offset: offset, stable: stable, data: slice)
                )

            case .create:
                let dirInode = try reader.readFileHandleInode()
                let name = try reader.readString()
                let modeRaw = try reader.readUInt32()
                let mode = NFS3CreateMode(rawValue: modeRaw) ?? .unchecked
                var initialSize: UInt64? = nil
                var initialMode: UInt32? = nil
                var createVerifier: Data? = nil
                switch mode {
                case .unchecked, .guarded:
                    let sattr = try readSetAttr3(&reader)
                    initialMode = sattr.mode
                    initialSize = sattr.size
                case .exclusive:
                    createVerifier = try reader.readFixedOpaque(8)
                }
                return XDRWriter.acceptedReply(
                    xid: header.xid,
                    body: await handleCreate(
                        dirInode: dirInode,
                        name: name,
                        mode: mode,
                        initialMode: initialMode,
                        initialSize: initialSize,
                        createVerifier: createVerifier
                    )
                )

            case .mkdir:
                let dirInode = try reader.readFileHandleInode()
                let name = try reader.readString()
                let sattr = try readSetAttr3(&reader)
                return XDRWriter.acceptedReply(
                    xid: header.xid,
                    body: await handleMkdir(dirInode: dirInode, name: name, initialMode: sattr.mode)
                )

            case .symlink:
                let dirInode = try reader.readFileHandleInode()
                let name = try reader.readString()
                _ = try readSetAttr3(&reader)
                let target = try reader.readString()
                return XDRWriter.acceptedReply(
                    xid: header.xid,
                    body: await handleSymlink(dirInode: dirInode, name: name, target: target)
                )

            case .remove:
                let dirInode = try reader.readFileHandleInode()
                let name = try reader.readString()
                return XDRWriter.acceptedReply(
                    xid: header.xid,
                    body: await handleRemove(dirInode: dirInode, name: name, isDirectoryRemoval: false)
                )

            case .rmdir:
                let dirInode = try reader.readFileHandleInode()
                let name = try reader.readString()
                return XDRWriter.acceptedReply(
                    xid: header.xid,
                    body: await handleRemove(dirInode: dirInode, name: name, isDirectoryRemoval: true)
                )

            case .rename:
                let fromDirInode = try reader.readFileHandleInode()
                let fromName = try reader.readString()
                let toDirInode = try reader.readFileHandleInode()
                let toName = try reader.readString()
                return XDRWriter.acceptedReply(
                    xid: header.xid,
                    body: await handleRename(
                        fromDirInode: fromDirInode,
                        fromName: fromName,
                        toDirInode: toDirInode,
                        toName: toName
                    )
                )

            case .readdir:
                let dirInode = try reader.readFileHandleInode()
                let cookie = try reader.readUInt64()
                _ = try reader.readFixedOpaque(8) // cookieverf
                let maxCount = try reader.readUInt32()
                return XDRWriter.acceptedReply(
                    xid: header.xid,
                    body: await handleReaddir(dirInode: dirInode, cookie: cookie, maxCount: maxCount, plus: false)
                )

            case .readdirPlus:
                let dirInode = try reader.readFileHandleInode()
                let cookie = try reader.readUInt64()
                _ = try reader.readFixedOpaque(8) // cookieverf
                _ = try reader.readUInt32() // dircount
                let maxCount = try reader.readUInt32()
                return XDRWriter.acceptedReply(
                    xid: header.xid,
                    body: await handleReaddir(dirInode: dirInode, cookie: cookie, maxCount: maxCount, plus: true)
                )

            case .fsstat:
                let inode = try reader.readFileHandleInode()
                return XDRWriter.acceptedReply(xid: header.xid, body: await handleFSStat(inode: inode))

            case .fsinfo:
                let inode = try reader.readFileHandleInode()
                return XDRWriter.acceptedReply(xid: header.xid, body: await handleFSInfo(inode: inode))

            case .pathconf:
                let inode = try reader.readFileHandleInode()
                return XDRWriter.acceptedReply(xid: header.xid, body: await handlePathconf(inode: inode))

            case .commit:
                let inode = try reader.readFileHandleInode()
                _ = try reader.readUInt64() // offset
                _ = try reader.readUInt32() // count
                return XDRWriter.acceptedReply(xid: header.xid, body: await handleCommit(inode: inode))

            case .mknod, .link:
                var out = XDRWriter()
                out.writeUInt32(NFS3Status.notSupp.rawValue)
                out.writeWccData(post: nil)
                if proc == .link {
                    out.writeWccData(post: nil)
                }
                return XDRWriter.acceptedReply(xid: header.xid, body: out.data)
            }
        } catch {
            return XDRWriter.acceptedReply(xid: header.xid, acceptStatus: 4) // GARBAGE_ARGS
        }
    }

    // MARK: - Procedure Handlers

    private func handleGetAttr(inode: UInt64) async -> Data {
        var out = XDRWriter()
        guard let attrs = await attributes(for: inode) else {
            out.writeUInt32(NFS3Status.noent.rawValue)
            return out.data
        }
        out.writeUInt32(NFS3Status.ok.rawValue)
        out.writeFattr3(attrs)
        return out.data
    }

    private func handleSetAttr(
        inode: UInt64,
        mode: UInt32?,
        newSize: UInt64?,
        modifiedTime: Double?
    ) async -> Data {
        var out = XDRWriter()
        let pre = await attributes(for: inode)

        if var eph = ephemeralNodes[inode] {
            if let mode {
                eph.mode = mode & 0o0777
            }
            if let newSize, !eph.isDirectory {
                let targetCount = Int(min(newSize, UInt64(Self.maxEphemeralNodeBytes)))
                if targetCount < eph.data.count {
                    eph.data = Data(eph.data.prefix(targetCount))
                } else if targetCount > eph.data.count {
                    eph.data.append(Data(repeating: 0, count: targetCount - eph.data.count))
                }
            }
            if let modifiedTime {
                eph.modifiedTime = modifiedTime
            }
            ephemeralNodes[inode] = eph
            pruneEphemeralNodesIfNeeded(keeping: inode)
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writeWccData(pre: pre, post: attributes(from: eph))
            return out.data
        }

        guard let node = await driveVolume.node(for: inode) else {
            out.writeUInt32(NFS3Status.noent.rawValue)
            out.writeWccData(pre: nil, post: nil)
            return out.data
        }

        if mode == nil && newSize == nil && modifiedTime == nil {
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writeWccData(pre: pre, post: pre)
            return out.data
        }

        // Ignore attribute mutations on root, account roots, or virtual `.od-refresh`.
        if node.kind == .root || node.kind == .refreshTrigger || { if case .cloudRoot = node.kind { return true }; return false }() {
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writeWccData(pre: pre, post: pre)
            return out.data
        }

        do {
            let signedSize = node.isDirectory ? nil : newSize.map { Int64(min($0, UInt64(Int64.max))) }
            let updated = try await driveVolume.setAttributes(
                itemId: inode,
                newSize: signedSize,
                modifiedTime: modifiedTime,
                posixMode: mode
            )
            if signedSize == 0 {
                // Ensure zero-byte truncate / overwrite commits cleanly if requested.
                scheduleCommit(for: inode, delaySeconds: 0.4)
            }
            let canMutateRoot = await driveVolume.allowsDirectRootMutations()
            let post = attributes(from: updated, canMutateRoot: canMutateRoot)
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writeWccData(pre: pre, post: post)
            return out.data
        } catch {
            out.writeUInt32(Self.nfsStatus(for: error).rawValue)
            out.writeWccData(pre: pre, post: pre)
            return out.data
        }
    }

    private func handleLookup(dirInode: UInt64, name: String) async -> Data {
        var out = XDRWriter()
        let dirAttrs = await attributes(for: dirInode)
        guard let dirAttrs, dirAttrs.isDirectory else {
            out.writeUInt32(dirAttrs == nil ? NFS3Status.noent.rawValue : NFS3Status.notdir.rawValue)
            out.writePostOpAttr(dirAttrs)
            return out.data
        }

        if name == "." {
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writeFileHandle(dirInode)
            out.writePostOpAttr(dirAttrs)
            out.writePostOpAttr(dirAttrs)
            return out.data
        }

        if name == ".." {
            let parentInode = await resolveParentInode(of: dirInode)
            let parentAttrs = await attributes(for: parentInode) ?? dirAttrs
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writeFileHandle(parentInode)
            out.writePostOpAttr(parentAttrs)
            out.writePostOpAttr(dirAttrs)
            return out.data
        }

        if let eph = findEphemeralChild(parentInode: dirInode, name: name) {
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writeFileHandle(eph.inode)
            out.writePostOpAttr(attributes(from: eph))
            out.writePostOpAttr(dirAttrs)
            return out.data
        }

        if Self.isEphemeralInode(dirInode) || Self.isEphemeralMetadataName(name) {
            out.writeUInt32(NFS3Status.noent.rawValue)
            out.writePostOpAttr(dirAttrs)
            return out.data
        }

        do {
            let node = try await driveVolume.lookup(name: name, inDirectory: dirInode)
            let canMutateRoot = await driveVolume.allowsDirectRootMutations()
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writeFileHandle(node.itemId)
            out.writePostOpAttr(attributes(from: node, canMutateRoot: canMutateRoot))
            out.writePostOpAttr(dirAttrs)
            return out.data
        } catch {
            out.writeUInt32(Self.nfsStatus(for: error).rawValue)
            out.writePostOpAttr(dirAttrs)
            return out.data
        }
    }

    private func handleAccess(inode: UInt64, requested: UInt32) async -> Data {
        var out = XDRWriter()
        guard let attrs = await attributes(for: inode) else {
            out.writeUInt32(NFS3Status.noent.rawValue)
            out.writePostOpAttr(nil)
            return out.data
        }
        let readOnlyMask = NFS3AccessMask.read | NFS3AccessMask.lookup | NFS3AccessMask.execute
        let allowed: UInt32
        if inode == DriveVolume.rootItemId, !(await driveVolume.allowsDirectRootMutations()) {
            allowed = requested & readOnlyMask
        } else {
            allowed = requested
        }
        out.writeUInt32(NFS3Status.ok.rawValue)
        out.writePostOpAttr(attrs)
        out.writeUInt32(allowed)
        return out.data
    }

    private func handleReadlink(inode: UInt64) async -> Data {
        var out = XDRWriter()
        if let eph = ephemeralNodes[inode] {
            guard let target = eph.symlinkTarget else {
                out.writeUInt32(NFS3Status.inval.rawValue)
                out.writePostOpAttr(attributes(from: eph))
                return out.data
            }
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writePostOpAttr(attributes(from: eph))
            out.writeString(target)
            return out.data
        }

        let attrs = await attributes(for: inode)
        guard let attrs else {
            out.writeUInt32(NFS3Status.noent.rawValue)
            out.writePostOpAttr(nil)
            return out.data
        }
        guard attrs.fileType == .symlink else {
            out.writeUInt32(NFS3Status.inval.rawValue)
            out.writePostOpAttr(attrs)
            return out.data
        }

        do {
            let target = try await driveVolume.readSymlinkTarget(itemId: inode)
            let updatedAttrs = await attributes(for: inode) ?? attrs
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writePostOpAttr(updatedAttrs)
            out.writeString(target)
            return out.data
        } catch {
            out.writeUInt32(Self.nfsStatus(for: error).rawValue)
            out.writePostOpAttr(attrs)
            return out.data
        }
    }

    private func handleRead(inode: UInt64, offset: UInt64, count: UInt32) async -> Data {
        var out = XDRWriter()
        if let eph = ephemeralNodes[inode] {
            guard !eph.isDirectory else {
                out.writeUInt32(NFS3Status.isdir.rawValue)
                out.writePostOpAttr(attributes(from: eph))
                return out.data
            }
            let total = UInt64(eph.data.count)
            let slice: Data
            let eof: Bool
            if offset >= total {
                slice = Data()
                eof = true
            } else {
                let start = Int(offset)
                let end = min(eph.data.count, start + Int(count))
                slice = Data(eph.data[start..<end])
                eof = end >= eph.data.count
            }
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writePostOpAttr(attributes(from: eph))
            out.writeUInt32(UInt32(slice.count))
            out.writeBool(eof)
            out.writeOpaque(slice)
            return out.data
        }

        let preAttrs = await attributes(for: inode)
        guard let preAttrs else {
            out.writeUInt32(NFS3Status.noent.rawValue)
            out.writePostOpAttr(nil)
            return out.data
        }
        guard !preAttrs.isDirectory else {
            out.writeUInt32(NFS3Status.isdir.rawValue)
            out.writePostOpAttr(preAttrs)
            return out.data
        }

        do {
            let signedOffset = Int64(min(offset, UInt64(Int64.max)))
            let data = try await driveVolume.read(
                itemId: inode,
                offset: signedOffset,
                length: Int(count)
            )
            let postAttrs = await attributes(for: inode) ?? preAttrs
            let eof = UInt64(signedOffset) + UInt64(data.count) >= postAttrs.size || data.count < Int(count)
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writePostOpAttr(postAttrs)
            out.writeUInt32(UInt32(data.count))
            out.writeBool(eof)
            out.writeOpaque(data)
            return out.data
        } catch {
            out.writeUInt32(Self.nfsStatus(for: error).rawValue)
            out.writePostOpAttr(preAttrs)
            return out.data
        }
    }

    private func handleWrite(inode: UInt64, offset: UInt64, stable: UInt32, data: Data) async -> Data {
        var out = XDRWriter()
        if var eph = ephemeralNodes[inode] {
            let pre = attributes(from: eph)
            guard !eph.isDirectory else {
                out.writeUInt32(NFS3Status.isdir.rawValue)
                out.writeWccData(pre: pre, post: pre)
                return out.data
            }
            let start = Int(min(offset, UInt64(Self.maxEphemeralNodeBytes)))
            let end = min(Self.maxEphemeralNodeBytes, start + data.count)
            let writeCount = max(0, end - start)
            if end > eph.data.count {
                eph.data.append(Data(repeating: 0, count: end - eph.data.count))
            }
            if writeCount > 0 {
                eph.data.replaceSubrange(start..<end, with: data.prefix(writeCount))
            }
            eph.modifiedTime = Date().timeIntervalSince1970
            ephemeralNodes[inode] = eph
            pruneEphemeralNodesIfNeeded(keeping: inode)

            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writeWccData(pre: pre, post: attributes(from: eph))
            out.writeUInt32(UInt32(writeCount))
            out.writeUInt32(stable == NFS3WriteStable.unstable ? NFS3WriteStable.unstable : NFS3WriteStable.fileSync)
            out.writeFixedOpaque(writeVerifier)
            return out.data
        }

        let pre = await attributes(for: inode)
        guard let pre else {
            out.writeUInt32(NFS3Status.noent.rawValue)
            out.writeWccData(pre: nil, post: nil)
            return out.data
        }
        guard !pre.isDirectory else {
            out.writeUInt32(NFS3Status.isdir.rawValue)
            out.writeWccData(pre: pre, post: pre)
            return out.data
        }

        do {
            let signedOffset = Int64(min(offset, UInt64(Int64.max)))
            let written = try await driveVolume.write(itemId: inode, offset: signedOffset, data: data)
            let delay = (stable == NFS3WriteStable.unstable) ? 2.0 : 0.3
            scheduleCommit(for: inode, delaySeconds: delay)

            let post = await attributes(for: inode) ?? pre
            let committed = (stable == NFS3WriteStable.unstable)
                ? NFS3WriteStable.unstable
                : NFS3WriteStable.fileSync
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writeWccData(pre: pre, post: post)
            out.writeUInt32(UInt32(written))
            out.writeUInt32(committed)
            out.writeFixedOpaque(writeVerifier)
            return out.data
        } catch {
            out.writeUInt32(Self.nfsStatus(for: error).rawValue)
            out.writeWccData(pre: pre, post: pre)
            return out.data
        }
    }

    private func handleCreate(
        dirInode: UInt64,
        name: String,
        mode: NFS3CreateMode,
        initialMode: UInt32?,
        initialSize: UInt64?,
        createVerifier: Data?
    ) async -> Data {
        var out = XDRWriter()
        let dirPre = await attributes(for: dirInode)
        guard let dirPre, dirPre.isDirectory else {
            out.writeUInt32(dirPre == nil ? NFS3Status.noent.rawValue : NFS3Status.notdir.rawValue)
            out.writeWccData(pre: dirPre, post: dirPre)
            return out.data
        }

        if Self.isEphemeralInode(dirInode) || Self.isEphemeralMetadataName(name) {
            if let existing = findEphemeralChild(parentInode: dirInode, name: name) {
                switch mode {
                case .unchecked:
                    var updated = existing
                    if let initialMode {
                        updated.mode = initialMode & 0o0777
                    }
                    if let initialSize, initialSize == 0 {
                        updated.data.removeAll()
                        updated.modifiedTime = Date().timeIntervalSince1970
                    }
                    ephemeralNodes[updated.inode] = updated
                    out.writeUInt32(NFS3Status.ok.rawValue)
                    out.writePostOpFileHandle(updated.inode)
                    out.writePostOpAttr(attributes(from: updated))
                    out.writeWccData(pre: dirPre, post: await attributes(for: dirInode))
                    return out.data
                case .guarded:
                    out.writeUInt32(NFS3Status.exist.rawValue)
                    out.writeWccData(pre: dirPre, post: dirPre)
                    return out.data
                case .exclusive:
                    let key = "\(dirInode):\(name)"
                    if let createVerifier, exclusiveCreateVerifiers[key] == createVerifier {
                        out.writeUInt32(NFS3Status.ok.rawValue)
                        out.writePostOpFileHandle(existing.inode)
                        out.writePostOpAttr(attributes(from: existing))
                        out.writeWccData(pre: dirPre, post: dirPre)
                        return out.data
                    }
                    out.writeUInt32(NFS3Status.exist.rawValue)
                    out.writeWccData(pre: dirPre, post: dirPre)
                    return out.data
                }
            }

            let created = allocateEphemeralNode(
                parentInode: dirInode,
                name: name,
                isDirectory: false,
                mode: initialMode.map { $0 & 0o0777 } ?? 0o644
            )
            if let createVerifier {
                recordExclusiveVerifier("\(dirInode):\(name)", verifier: createVerifier)
            }
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writePostOpFileHandle(created.inode)
            out.writePostOpAttr(attributes(from: created))
            out.writeWccData(pre: dirPre, post: await attributes(for: dirInode))
            return out.data
        }

        if let existing = try? await driveVolume.lookup(name: name, inDirectory: dirInode) {
            switch mode {
            case .unchecked:
                var node = existing
                if initialSize != nil || initialMode != nil {
                    node = (try? await driveVolume.setAttributes(
                        itemId: existing.itemId,
                        newSize: existing.isDirectory ? nil : initialSize.map { Int64(min($0, UInt64(Int64.max))) },
                        modifiedTime: Date().timeIntervalSince1970,
                        posixMode: initialMode
                    )) ?? existing
                }
                let canMutateRoot = await driveVolume.allowsDirectRootMutations()
                out.writeUInt32(NFS3Status.ok.rawValue)
                out.writePostOpFileHandle(node.itemId)
                out.writePostOpAttr(attributes(from: node, canMutateRoot: canMutateRoot))
                out.writeWccData(pre: dirPre, post: await attributes(for: dirInode))
                return out.data
            case .guarded:
                out.writeUInt32(NFS3Status.exist.rawValue)
                out.writeWccData(pre: dirPre, post: dirPre)
                return out.data
            case .exclusive:
                let key = "\(dirInode):\(name)"
                if let createVerifier, exclusiveCreateVerifiers[key] == createVerifier {
                    let canMutateRoot = await driveVolume.allowsDirectRootMutations()
                    out.writeUInt32(NFS3Status.ok.rawValue)
                    out.writePostOpFileHandle(existing.itemId)
                    out.writePostOpAttr(attributes(from: existing, canMutateRoot: canMutateRoot))
                    out.writeWccData(pre: dirPre, post: dirPre)
                    return out.data
                }
                out.writeUInt32(NFS3Status.exist.rawValue)
                out.writeWccData(pre: dirPre, post: dirPre)
                return out.data
            }
        }

        do {
            var created = try await driveVolume.createItem(name: name, isDirectory: false, inDirectory: dirInode)
            if let initialMode {
                created = (try? await driveVolume.setAttributes(
                    itemId: created.itemId,
                    newSize: nil,
                    modifiedTime: nil,
                    posixMode: initialMode
                )) ?? created
            }
            if let createVerifier {
                recordExclusiveVerifier("\(dirInode):\(name)", verifier: createVerifier)
            }
            scheduleCommit(for: created.itemId, delaySeconds: 0.4)
            let canMutateRoot = await driveVolume.allowsDirectRootMutations()
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writePostOpFileHandle(created.itemId)
            out.writePostOpAttr(attributes(from: created, canMutateRoot: canMutateRoot))
            out.writeWccData(pre: dirPre, post: await attributes(for: dirInode))
            return out.data
        } catch {
            out.writeUInt32(Self.nfsStatus(for: error).rawValue)
            out.writeWccData(pre: dirPre, post: dirPre)
            return out.data
        }
    }

    private func handleMkdir(dirInode: UInt64, name: String, initialMode: UInt32?) async -> Data {
        var out = XDRWriter()
        let dirPre = await attributes(for: dirInode)
        guard let dirPre, dirPre.isDirectory else {
            out.writeUInt32(dirPre == nil ? NFS3Status.noent.rawValue : NFS3Status.notdir.rawValue)
            out.writeWccData(pre: dirPre, post: dirPre)
            return out.data
        }

        if Self.isEphemeralInode(dirInode) || Self.isEphemeralMetadataName(name) {
            if findEphemeralChild(parentInode: dirInode, name: name) != nil {
                out.writeUInt32(NFS3Status.exist.rawValue)
                out.writeWccData(pre: dirPre, post: dirPre)
                return out.data
            }
            let created = allocateEphemeralNode(
                parentInode: dirInode,
                name: name,
                isDirectory: true,
                mode: initialMode.map { $0 & 0o0777 } ?? 0o755
            )
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writePostOpFileHandle(created.inode)
            out.writePostOpAttr(attributes(from: created))
            out.writeWccData(pre: dirPre, post: await attributes(for: dirInode))
            return out.data
        }

        do {
            var created = try await driveVolume.createItem(name: name, isDirectory: true, inDirectory: dirInode)
            if let initialMode {
                created = (try? await driveVolume.setAttributes(
                    itemId: created.itemId,
                    newSize: nil,
                    modifiedTime: nil,
                    posixMode: initialMode
                )) ?? created
            }
            DarwinNotifier.shared.post(.changed)
            let canMutateRoot = await driveVolume.allowsDirectRootMutations()
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writePostOpFileHandle(created.itemId)
            out.writePostOpAttr(attributes(from: created, canMutateRoot: canMutateRoot))
            out.writeWccData(pre: dirPre, post: await attributes(for: dirInode))
            return out.data
        } catch {
            out.writeUInt32(Self.nfsStatus(for: error).rawValue)
            out.writeWccData(pre: dirPre, post: dirPre)
            return out.data
        }
    }

    private func handleSymlink(dirInode: UInt64, name: String, target: String) async -> Data {
        var out = XDRWriter()
        let dirPre = await attributes(for: dirInode)
        guard let dirPre, dirPre.isDirectory else {
            out.writeUInt32(dirPre == nil ? NFS3Status.noent.rawValue : NFS3Status.notdir.rawValue)
            out.writeWccData(pre: dirPre, post: dirPre)
            return out.data
        }

        if Self.isEphemeralInode(dirInode) || Self.isEphemeralMetadataName(name) {
            if findEphemeralChild(parentInode: dirInode, name: name) != nil {
                out.writeUInt32(NFS3Status.exist.rawValue)
                out.writeWccData(pre: dirPre, post: dirPre)
                return out.data
            }
            let created = allocateEphemeralNode(
                parentInode: dirInode,
                name: name,
                isDirectory: false,
                mode: 0o777,
                symlinkTarget: target
            )
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writePostOpFileHandle(created.inode)
            out.writePostOpAttr(attributes(from: created))
            out.writeWccData(pre: dirPre, post: await attributes(for: dirInode))
            return out.data
        }

        do {
            let created = try await driveVolume.createSymlink(name: name, target: target, inDirectory: dirInode)
            DarwinNotifier.shared.post(.changed)
            let canMutateRoot = await driveVolume.allowsDirectRootMutations()
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writePostOpFileHandle(created.itemId)
            out.writePostOpAttr(attributes(from: created, canMutateRoot: canMutateRoot))
            out.writeWccData(pre: dirPre, post: await attributes(for: dirInode))
            return out.data
        } catch {
            out.writeUInt32(Self.nfsStatus(for: error).rawValue)
            out.writeWccData(pre: dirPre, post: dirPre)
            return out.data
        }
    }

    private func handleRemove(dirInode: UInt64, name: String, isDirectoryRemoval: Bool) async -> Data {
        var out = XDRWriter()
        let dirPre = await attributes(for: dirInode)
        guard let dirPre, dirPre.isDirectory else {
            out.writeUInt32(dirPre == nil ? NFS3Status.noent.rawValue : NFS3Status.notdir.rawValue)
            out.writeWccData(pre: dirPre, post: dirPre)
            return out.data
        }

        if let eph = findEphemeralChild(parentInode: dirInode, name: name) {
            if isDirectoryRemoval && !eph.isDirectory {
                out.writeUInt32(NFS3Status.notdir.rawValue)
                out.writeWccData(pre: dirPre, post: dirPre)
                return out.data
            }
            if !isDirectoryRemoval && eph.isDirectory {
                out.writeUInt32(NFS3Status.isdir.rawValue)
                out.writeWccData(pre: dirPre, post: dirPre)
                return out.data
            }
            if isDirectoryRemoval && ephemeralNodes.values.contains(where: { $0.parentInode == eph.inode }) {
                out.writeUInt32(NFS3Status.notEmpty.rawValue)
                out.writeWccData(pre: dirPre, post: dirPre)
                return out.data
            }
            ephemeralNodes.removeValue(forKey: eph.inode)
            exclusiveCreateVerifiers.removeValue(forKey: "\(dirInode):\(name)")
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writeWccData(pre: dirPre, post: await attributes(for: dirInode))
            return out.data
        }

        if Self.isEphemeralInode(dirInode) || Self.isEphemeralMetadataName(name) {
            out.writeUInt32(NFS3Status.noent.rawValue)
            out.writeWccData(pre: dirPre, post: dirPre)
            return out.data
        }

        do {
            let target = try await driveVolume.lookup(name: name, inDirectory: dirInode)
            if isDirectoryRemoval && !target.isDirectory {
                out.writeUInt32(NFS3Status.notdir.rawValue)
                out.writeWccData(pre: dirPre, post: dirPre)
                return out.data
            }
            if !isDirectoryRemoval && target.isDirectory {
                out.writeUInt32(NFS3Status.isdir.rawValue)
                out.writeWccData(pre: dirPre, post: dirPre)
                return out.data
            }

            pendingCommitTasks.removeValue(forKey: target.itemId)?.cancel()
            try await driveVolume.removeItem(itemId: target.itemId)
            exclusiveCreateVerifiers.removeValue(forKey: "\(dirInode):\(name)")
            DarwinNotifier.shared.post(.changed)
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writeWccData(pre: dirPre, post: await attributes(for: dirInode))
            return out.data
        } catch {
            out.writeUInt32(Self.nfsStatus(for: error).rawValue)
            out.writeWccData(pre: dirPre, post: dirPre)
            return out.data
        }
    }

    private func handleRename(
        fromDirInode: UInt64,
        fromName: String,
        toDirInode: UInt64,
        toName: String
    ) async -> Data {
        var out = XDRWriter()
        let fromDirPre = await attributes(for: fromDirInode)
        let toDirPre = await attributes(for: toDirInode)
        guard let fromDirPre, fromDirPre.isDirectory else {
            out.writeUInt32(fromDirPre == nil ? NFS3Status.noent.rawValue : NFS3Status.notdir.rawValue)
            out.writeWccData(pre: fromDirPre, post: fromDirPre)
            out.writeWccData(pre: toDirPre, post: toDirPre)
            return out.data
        }
        guard let toDirPre, toDirPre.isDirectory else {
            out.writeUInt32(toDirPre == nil ? NFS3Status.noent.rawValue : NFS3Status.notdir.rawValue)
            out.writeWccData(pre: fromDirPre, post: fromDirPre)
            out.writeWccData(pre: toDirPre, post: toDirPre)
            return out.data
        }

        if fromDirInode == toDirInode && fromName == toName {
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writeWccData(pre: fromDirPre, post: fromDirPre)
            out.writeWccData(pre: toDirPre, post: toDirPre)
            return out.data
        }

        if let ephSrc = findEphemeralChild(parentInode: fromDirInode, name: fromName) {
            if let existingDst = findEphemeralChild(parentInode: toDirInode, name: toName) {
                guard existingDst.isDirectory == ephSrc.isDirectory else {
                    out.writeUInt32(existingDst.isDirectory ? NFS3Status.isdir.rawValue : NFS3Status.notdir.rawValue)
                    out.writeWccData(pre: fromDirPre, post: fromDirPre)
                    out.writeWccData(pre: toDirPre, post: toDirPre)
                    return out.data
                }
                ephemeralNodes.removeValue(forKey: existingDst.inode)
            }
            var moved = ephSrc
            moved.parentInode = toDirInode
            moved.name = toName
            moved.modifiedTime = Date().timeIntervalSince1970
            ephemeralNodes[moved.inode] = moved
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writeWccData(pre: fromDirPre, post: await attributes(for: fromDirInode))
            out.writeWccData(pre: toDirPre, post: await attributes(for: toDirInode))
            return out.data
        }

        if Self.isEphemeralInode(fromDirInode) || Self.isEphemeralMetadataName(fromName) {
            out.writeUInt32(NFS3Status.noent.rawValue)
            out.writeWccData(pre: fromDirPre, post: fromDirPre)
            out.writeWccData(pre: toDirPre, post: toDirPre)
            return out.data
        }

        if Self.isEphemeralInode(toDirInode) || Self.isEphemeralMetadataName(toName) {
            out.writeUInt32(NFS3Status.xdev.rawValue)
            out.writeWccData(pre: fromDirPre, post: fromDirPre)
            out.writeWccData(pre: toDirPre, post: toDirPre)
            return out.data
        }

        do {
            let sourceNode = try await driveVolume.lookup(name: fromName, inDirectory: fromDirInode)
            let isScratchSource: Bool = if case .scratch = sourceNode.kind { true } else { false }
            if isScratchSource {
                pendingCommitTasks.removeValue(forKey: sourceNode.itemId)?.cancel()
            } else {
                try? await flushCommit(for: sourceNode.itemId, awaitUpload: false)
            }

            if let existingDest = try? await driveVolume.lookup(name: toName, inDirectory: toDirInode),
               existingDest.itemId != sourceNode.itemId {
                guard !existingDest.isDirectory else {
                    out.writeUInt32(NFS3Status.isdir.rawValue)
                    out.writeWccData(pre: fromDirPre, post: fromDirPre)
                    out.writeWccData(pre: toDirPre, post: toDirPre)
                    return out.data
                }
                pendingCommitTasks.removeValue(forKey: existingDest.itemId)?.cancel()
                try await driveVolume.removeItem(itemId: existingDest.itemId)
            }

            _ = try await driveVolume.renameItem(
                itemId: sourceNode.itemId,
                toNewName: toName,
                inDestinationDirectory: toDirInode
            )
            if isScratchSource {
                scheduleCommit(for: sourceNode.itemId, delaySeconds: 0.15)
            }
            DarwinNotifier.shared.post(.changed)
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writeWccData(pre: fromDirPre, post: await attributes(for: fromDirInode))
            out.writeWccData(pre: toDirPre, post: await attributes(for: toDirInode))
            return out.data
        } catch {
            out.writeUInt32(Self.nfsStatus(for: error).rawValue)
            out.writeWccData(pre: fromDirPre, post: fromDirPre)
            out.writeWccData(pre: toDirPre, post: toDirPre)
            return out.data
        }
    }

    private func handleReaddir(dirInode: UInt64, cookie: UInt64, maxCount: UInt32, plus: Bool) async -> Data {
        var out = XDRWriter()
        let dirAttrs = await attributes(for: dirInode)
        guard let dirAttrs, dirAttrs.isDirectory else {
            out.writeUInt32(dirAttrs == nil ? NFS3Status.noent.rawValue : NFS3Status.notdir.rawValue)
            out.writePostOpAttr(dirAttrs)
            return out.data
        }

        do {
            let entries = try await buildDirectoryEntries(for: dirInode, dirAttrs: dirAttrs)
            let budget = min(max(1024, Int(maxCount)), 512 * 1024)

            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writePostOpAttr(dirAttrs)
            out.writeFixedOpaque(Data(repeating: 0, count: 8)) // cookieverf

            var emitted = 0
            var nextIndex = entries.count
            for (idx, entry) in entries.enumerated() where entry.cookie > cookie {
                var scratch = XDRWriter(capacity: 256)
                scratch.writeBool(true)
                scratch.writeUInt64(entry.inode)
                scratch.writeString(entry.name)
                scratch.writeUInt64(entry.cookie)
                if plus {
                    scratch.writePostOpAttr(entry.attrs)
                    scratch.writePostOpFileHandle(entry.inode)
                }

                // Always leave room for terminating value_follows (4) + eof (4).
                if emitted > 0 && out.data.count + scratch.data.count + 8 > budget {
                    nextIndex = idx
                    break
                }
                out.appendRaw(scratch.data)
                emitted += 1
            }

            let eof = nextIndex >= entries.count
            out.writeBool(false) // no more entries in this reply
            out.writeBool(eof)
            return out.data
        } catch {
            out.writeUInt32(Self.nfsStatus(for: error).rawValue)
            out.writePostOpAttr(dirAttrs)
            return out.data
        }
    }

    private func attributesOrRoot(for inode: UInt64) async -> NFSAttributes? {
        if let direct = await attributes(for: inode) {
            return direct
        }
        return await attributes(for: DriveVolume.rootItemId)
    }

    private func handleFSStat(inode: UInt64) async -> Data {
        var out = XDRWriter()
        let attrs = await attributesOrRoot(for: inode)
        let quota = await driveVolume.aggregatedStorageQuota()
        let fallbackTotal: UInt64 = 10_000_000_000_000 // 10 TB nominal fallback for unlimited accounts
        let tbytes = quota?.totalBytes ?? fallbackTotal
        let abytes = quota?.availableBytes ?? fallbackTotal

        out.writeUInt32(NFS3Status.ok.rawValue)
        out.writePostOpAttr(attrs)
        out.writeUInt64(tbytes)
        out.writeUInt64(abytes)
        out.writeUInt64(abytes)
        out.writeUInt64(10_000_000) // tfiles
        out.writeUInt64(9_999_000)  // ffiles
        out.writeUInt64(9_999_000)  // afiles
        out.writeUInt32(5)          // invarsec
        return out.data
    }

    private func handleFSInfo(inode: UInt64) async -> Data {
        var out = XDRWriter()
        let attrs = await attributesOrRoot(for: inode)
        out.writeUInt32(NFS3Status.ok.rawValue)
        out.writePostOpAttr(attrs)
        out.writeUInt32(131_072)         // rtmax
        out.writeUInt32(131_072)         // rtpref
        out.writeUInt32(4096)            // rtmult
        out.writeUInt32(131_072)         // wtmax
        out.writeUInt32(131_072)         // wtpref
        out.writeUInt32(4096)            // wtmult
        out.writeUInt32(32_768)          // dtpref
        out.writeUInt64(1 << 50)         // maxfilesize
        out.writeUInt32(1)               // time_delta.seconds
        out.writeUInt32(0)               // time_delta.nseconds
        out.writeUInt32(0x1A)            // FSF3_SYMLINK | FSF3_HOMOGENEOUS | FSF3_CANSETTIME
        return out.data
    }

    private func handlePathconf(inode: UInt64) async -> Data {
        var out = XDRWriter()
        let attrs = await attributesOrRoot(for: inode)
        out.writeUInt32(NFS3Status.ok.rawValue)
        out.writePostOpAttr(attrs)
        out.writeUInt32(1)    // linkmax
        out.writeUInt32(255)  // name_max
        out.writeBool(true)   // no_trunc
        out.writeBool(true)   // chown_restricted
        out.writeBool(true)   // case_insensitive
        out.writeBool(true)   // case_preserving
        return out.data
    }

    private func handleCommit(inode: UInt64) async -> Data {
        var out = XDRWriter()
        if let eph = ephemeralNodes[inode] {
            let attrs = attributes(from: eph)
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writeWccData(pre: attrs, post: attrs)
            out.writeFixedOpaque(writeVerifier)
            return out.data
        }

        let pre = await attributes(for: inode)
        guard let pre else {
            out.writeUInt32(NFS3Status.noent.rawValue)
            out.writeWccData(pre: nil, post: nil)
            return out.data
        }

        do {
            try await flushCommit(for: inode, awaitUpload: false)
            let post = await attributes(for: inode) ?? pre
            out.writeUInt32(NFS3Status.ok.rawValue)
            out.writeWccData(pre: pre, post: post)
            out.writeFixedOpaque(writeVerifier)
            return out.data
        } catch {
            out.writeUInt32(Self.nfsStatus(for: error).rawValue)
            out.writeWccData(pre: pre, post: pre)
            return out.data
        }
    }

    // MARK: - Commit Scheduling & Directory/Attribute Resolution

    private func scheduleCommit(for itemId: UInt64, delaySeconds: Double) {
        pendingCommitTasks[itemId]?.cancel()
        pendingCommitTasks[itemId] = Task { [weak self] in
            let nanos = UInt64(max(0.05, delaySeconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await self?.runScheduledCommit(itemId: itemId)
        }
    }

    private func runScheduledCommit(itemId: UInt64) async {
        pendingCommitTasks.removeValue(forKey: itemId)
        _ = try? await flushCommit(for: itemId, awaitUpload: false)
    }

    private func flushCommit(for itemId: UInt64, awaitUpload: Bool = false) async throws {
        pendingCommitTasks.removeValue(forKey: itemId)?.cancel()
        if let existing = inFlightCommits[itemId] {
            try await existing.value
        }
        let dv = driveVolume
        let task = Task {
            try await dv.closeAndCommitIfDirty(itemId: itemId, awaitUpload: awaitUpload)
            DarwinNotifier.shared.post(.changed)
        }
        inFlightCommits[itemId] = task
        defer { inFlightCommits.removeValue(forKey: itemId) }
        try await task.value
    }

    private func buildDirectoryEntries(for dirInode: UInt64, dirAttrs: NFSAttributes) async throws -> [DirectoryEntry] {
        let parentInode = await resolveParentInode(of: dirInode)
        let parentAttrs = await attributes(for: parentInode) ?? dirAttrs

        var items: [(inode: UInt64, name: String, attrs: NFSAttributes)] = []
        if !Self.isEphemeralInode(dirInode) {
            let canMutateRoot = await driveVolume.allowsDirectRootMutations()
            let nodes = try await driveVolume.listDirectory(itemId: dirInode)
            for node in nodes {
                items.append((node.itemId, node.name, attributes(from: node, canMutateRoot: canMutateRoot)))
            }
        }

        let ephChildren = ephemeralNodes.values
            .filter { $0.parentInode == dirInode }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for eph in ephChildren {
            items.append((eph.inode, eph.name, attributes(from: eph)))
        }

        var result: [DirectoryEntry] = [
            DirectoryEntry(inode: dirInode, name: ".", attrs: dirAttrs, cookie: 1),
            DirectoryEntry(inode: parentInode, name: "..", attrs: parentAttrs, cookie: 2)
        ]
        var nextCookie: UInt64 = 3
        for item in items {
            result.append(DirectoryEntry(inode: item.inode, name: item.name, attrs: item.attrs, cookie: nextCookie))
            nextCookie += 1
        }
        return result
    }

    private func resolveParentInode(of inode: UInt64) async -> UInt64 {
        if inode == DriveVolume.rootItemId {
            return DriveVolume.rootItemId
        }
        if let eph = ephemeralNodes[inode] {
            return eph.parentInode
        }
        if let node = await driveVolume.node(for: inode) {
            return node.parentItemId == 1 ? DriveVolume.rootItemId : node.parentItemId
        }
        return DriveVolume.rootItemId
    }

    private func attributes(for inode: UInt64) async -> NFSAttributes? {
        if let eph = ephemeralNodes[inode] {
            return attributes(from: eph)
        }
        guard let node = await driveVolume.node(for: inode) else {
            return nil
        }
        let canMutateRoot = await driveVolume.allowsDirectRootMutations()
        return attributes(from: node, canMutateRoot: canMutateRoot)
    }

    private func attributes(from node: DriveVolume.VFSNode, canMutateRoot: Bool) -> NFSAttributes {
        let isReadOnlyRoot = (node.kind == .root && !canMutateRoot)
        let fileType: NFS3FileType = node.isSymlink ? .symlink : (node.isDirectory ? .directory : .regular)
        let defaultMode: UInt32 = node.isSymlink ? 0o777 : (node.isDirectory ? (isReadOnlyRoot ? 0o555 : 0o755) : 0o644)
        let mode = node.posixMode ?? defaultMode
        let isLocalScratch: Bool = if case .scratch = node.kind { true } else { false }
        let usedBytes: UInt64 = (isLocalScratch && !node.isDirectory) ? UInt64(max(0, node.size)) : 0
        return NFSAttributes(
            fileType: fileType,
            mode: mode,
            nlink: node.isDirectory ? 2 : 1,
            uid: uid,
            gid: gid,
            size: UInt64(max(0, node.size)),
            usedBytes: usedBytes,
            fileId: node.itemId,
            modifiedTime: node.modifiedTime
        )
    }

    private func attributes(from eph: EphemeralNode) -> NFSAttributes {
        let fileType: NFS3FileType = eph.symlinkTarget != nil ? .symlink : (eph.isDirectory ? .directory : .regular)
        let size: UInt64 = if let sym = eph.symlinkTarget {
            UInt64(sym.utf8.count)
        } else {
            UInt64(eph.isDirectory ? 0 : eph.data.count)
        }
        return NFSAttributes(
            fileType: fileType,
            mode: eph.mode,
            nlink: eph.isDirectory ? 2 : 1,
            uid: uid,
            gid: gid,
            size: size,
            usedBytes: 0,
            fileId: eph.inode,
            modifiedTime: eph.modifiedTime
        )
    }

    private func allocateEphemeralNode(
        parentInode: UInt64,
        name: String,
        isDirectory: Bool,
        mode: UInt32? = nil,
        symlinkTarget: String? = nil
    ) -> EphemeralNode {
        let inode = nextEphemeralInode
        nextEphemeralInode += 1
        let resolvedMode = (mode ?? (symlinkTarget != nil ? 0o777 : (isDirectory ? 0o755 : 0o644))) & 0o0777
        let node = EphemeralNode(
            inode: inode,
            parentInode: parentInode,
            name: name,
            isDirectory: isDirectory,
            mode: resolvedMode,
            symlinkTarget: symlinkTarget,
            data: Data(),
            modifiedTime: Date().timeIntervalSince1970
        )
        ephemeralNodes[inode] = node
        pruneEphemeralNodesIfNeeded(keeping: inode)
        return node
    }

    private func pruneEphemeralNodesIfNeeded(keeping keptInode: UInt64) {
        var totalBytes = ephemeralNodes.values.reduce(0) { $0 + $1.data.count }
        if ephemeralNodes.count <= Self.maxEphemeralNodes && totalBytes <= Self.maxEphemeralTotalBytes {
            return
        }
        let ordered = ephemeralNodes.values
            .filter { $0.inode != keptInode && !$0.isDirectory }
            .sorted { $0.modifiedTime < $1.modifiedTime }
        for node in ordered {
            guard ephemeralNodes.count > Self.maxEphemeralNodes || totalBytes > Self.maxEphemeralTotalBytes else {
                break
            }
            if ephemeralNodes.removeValue(forKey: node.inode) != nil {
                totalBytes -= node.data.count
            }
        }
    }

    private func recordExclusiveVerifier(_ key: String, verifier: Data) {
        if exclusiveCreateVerifiers.count >= Self.maxExclusiveVerifiers {
            exclusiveCreateVerifiers.removeAll(keepingCapacity: true)
        }
        exclusiveCreateVerifiers[key] = verifier
    }

    private func findEphemeralChild(parentInode: UInt64, name: String) -> EphemeralNode? {
        ephemeralNodes.values.first { $0.parentInode == parentInode && $0.name == name }
    }

    private static func isEphemeralInode(_ inode: UInt64) -> Bool {
        inode >= ephemeralInodeStart
    }

    private static func isEphemeralMetadataName(_ name: String) -> Bool {
        name.hasPrefix("._") || ephemeralPrefixNames.contains(name)
    }

    private func readSetAttr3(_ reader: inout XDRReader) throws -> (mode: UInt32?, size: UInt64?, modifiedTime: Double?) {
        var mode: UInt32? = nil
        if try reader.readBool() {
            mode = try reader.readUInt32() & 0o0777
        }
        if try reader.readBool() { _ = try reader.readUInt32() } // uid
        if try reader.readBool() { _ = try reader.readUInt32() } // gid

        var size: UInt64? = nil
        if try reader.readBool() {
            size = try reader.readUInt64()
        }

        let atimeHow = try reader.readUInt32()
        if atimeHow == 2 {
            _ = try reader.readUInt32()
            _ = try reader.readUInt32()
        }

        var modifiedTime: Double? = nil
        let mtimeHow = try reader.readUInt32()
        if mtimeHow == 1 {
            modifiedTime = Date().timeIntervalSince1970
        } else if mtimeHow == 2 {
            let secs = try reader.readUInt32()
            let nsecs = try reader.readUInt32()
            modifiedTime = Double(secs) + Double(nsecs) / 1_000_000_000.0
        }
        return (mode, size, modifiedTime)
    }

    private static func nfsStatus(for error: Error) -> NFS3Status {
        guard let posix = error as? POSIXError else {
            return .io
        }
        switch posix.code {
        case .ENOENT: return .noent
        case .EEXIST: return .exist
        case .EISDIR: return .isdir
        case .ENOTDIR: return .notdir
        case .EPERM: return .perm
        case .EACCES: return .acces
        case .EXDEV: return .xdev
        case .ENOTEMPTY: return .notEmpty
        case .EROFS: return .rofs
        case .EINVAL: return .inval
        case .ENAMETOOLONG: return .nameTooLong
        default: return .io
        }
    }
}

import CryptoKit
import Foundation
import FSKit
import OpenDriveCore

/// `FSVolume` implementation forwarding POSIX VFS calls to `DriveVolume`.
@available(macOS 15.4, *)
public final class OpenDriveVolume: FSVolume,
    FSVolume.Operations,
    FSVolume.PathConfOperations,
    FSVolume.OpenCloseOperations,
    FSVolume.ReadWriteOperations,
    FSVolume.XattrOperations,
    FSVolume.AccessCheckOperations,
    @unchecked Sendable
{
    private let driveVolume: DriveVolume
    private let itemsLock = NSLock()
    private var fsItemsById: [UInt64: OpenDriveFSItem] = [:]

    public init(volumeID: FSVolume.Identifier, volumeName: FSFileName, driveVolume: DriveVolume) {
        self.driveVolume = driveVolume
        super.init(volumeID: volumeID, volumeName: volumeName)
    }

    public func bootstrapAccounts() async {
        await Self.loadRegisteredAccounts(into: driveVolume)
        await driveVolume.startBackgroundSyncLoop(intervalSeconds: 30.0)

        let dv = self.driveVolume
        DarwinNotifier.shared.observe(.signal) {
            Task {
                await Self.loadRegisteredAccounts(into: dv)
                await dv.syncAllAccountsOnce()
            }
        }
        DarwinNotifier.shared.observe(.cancelUpload) {
            Task {
                await dv.syncAllAccountsOnce()
            }
        }
        NetworkPathObserver.shared.observe { isMetered, isOffline in
            Task {
                await dv.setNetworkStateForAll(isMetered: isMetered, isOffline: isOffline)
            }
        }
    }

    private static func loadRegisteredAccounts(into driveVolume: DriveVolume) async {
        let regURL = OpenDrivePaths.accountsRegistryURL
        guard let cache = try? ChunkCache() else {
            return
        }
        let accounts: [CloudAccount]
        if let data = try? Data(contentsOf: regURL),
           let decoded = try? JSONDecoder().decode([CloudAccount].self, from: data) {
            accounts = decoded
        } else {
            accounts = []
        }

        await driveVolume.unregisterRemovedAccounts(keepingIds: Set(accounts.map(\.id)))

        let clientId = UserDefaults.standard.string(forKey: "googleClientId") ?? ""
        let clientSecret = UserDefaults.standard.string(forKey: "googleClientSecret")
        for acc in accounts {
            guard let store = try? MetadataStore(databaseURL: OpenDrivePaths.databaseURL(for: acc.id)) else {
                continue
            }
            try? await store.upsertAccount(acc)
            let client = GoogleDriveClient(accountId: acc.id, clientId: clientId, clientSecret: clientSecret)
            let reader = RangeReader(cache: cache) { driveId, offset, length in
                try await client.downloadByteRange(driveId: driveId, offset: offset, length: length)
            }
            let uploader = UploadEngine(store: store, client: client)
            let syncer = SyncEngine(accountId: acc.id, store: store, client: client, cache: cache)
            let mkData = try? await KeychainStore.shared.loadMasterKey(for: acc.id)
            let masterKey = mkData.map { SymmetricKey(data: $0) }

            let stack = DriveVolume.MountedCloudStack(
                account: acc,
                store: store,
                client: client,
                reader: reader,
                uploader: uploader,
                syncer: syncer,
                masterKey: masterKey
            )
            await driveVolume.registerCloudStack(stack)
        }
    }

    // MARK: - FSVolume.PathConfOperations & Capabilities

    public var maximumLinkCount: Int { 1 }
    public var maximumNameLength: Int { 255 }
    public var restrictsOwnershipChanges: Bool { false }
    public var truncatesLongNames: Bool { false }
    public var maximumXattrSize: Int { 64 * 1024 }
    public var maximumFileSize: UInt64 { UInt64(Int64.max) }

    public var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsPersistentObjectIDs = true
        caps.supportsSymbolicLinks = false
        caps.supportsHardLinks = false
        caps.supports2TBFiles = true
        caps.supports64BitObjectIDs = true
        caps.supportsFastStatFS = true
        caps.supportsHiddenFiles = true
        caps.caseFormat = .insensitiveCasePreserving
        return caps
    }

    public var volumeStatistics: FSStatFSResult {
        let stats = FSStatFSResult(fileSystemTypeName: OpenDrivePaths.fsShortName)
        stats.blockSize = 4096
        stats.ioSize = OpenDrivePaths.defaultChunkSize
        let totalBytes: UInt64 = 1024 * 1024 * 1024 * 1024 // 1 TiB virtual capacity
        stats.totalBytes = totalBytes
        stats.availableBytes = totalBytes / 2
        stats.freeBytes = totalBytes / 2
        stats.usedBytes = totalBytes / 2
        stats.totalFiles = 1_000_000
        stats.freeFiles = 900_000
        return stats
    }

    // MARK: - Lifecycle (Activate, Mount, Unmount, Synchronize, Reclaim)

    public func activate(
        options: FSTaskOptions,
        replyHandler reply: @escaping (FSItem?, (any Error)?) -> Void
    ) {
        Task {
            let rootVFS = await driveVolume.rootNode()
            let rootItem = internFSItem(for: rootVFS)
            reply(rootItem, nil)
        }
    }

    public func deactivate(
        options: FSDeactivateOptions,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        Task {
            await driveVolume.stopBackgroundSyncLoop()
            reply(nil)
        }
    }

    public func mount(
        options: FSTaskOptions,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        reply(nil)
    }

    public func unmount(replyHandler reply: @escaping () -> Void) {
        Task {
            await driveVolume.stopBackgroundSyncLoop()
            reply()
        }
    }

    public func synchronize(
        flags: FSSyncFlags,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        Task {
            await driveVolume.syncAllAccountsOnce()
            reply(nil)
        }
    }

    public func reclaimItem(
        _ item: FSItem,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        guard let fdItem = item as? OpenDriveFSItem else {
            reply(nil)
            return
        }
        itemsLock.lock()
        if #available(macOS 27.0, *) {
            _ = fdItem.tryReclaim {
                self.fsItemsById.removeValue(forKey: fdItem.itemId)
            }
        } else {
            self.fsItemsById.removeValue(forKey: fdItem.itemId)
        }
        itemsLock.unlock()
        reply(nil)
    }

    // MARK: - Lookup & Directory Enumeration

    public func lookupItem(
        named name: FSFileName,
        inDirectory directory: FSItem,
        replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        guard let dirItem = directory as? OpenDriveFSItem,
              let nameStr = name.string else {
            reply(nil, nil, POSIXError(.ENOENT))
            return
        }
        Task {
            do {
                let foundNode = try await driveVolume.lookup(name: nameStr, inDirectory: dirItem.itemId)
                let fsItem = internFSItem(for: foundNode)
                reply(fsItem, FSFileName(string: foundNode.name), nil)
            } catch {
                reply(nil, nil, error)
            }
        }
    }

    public func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker,
        replyHandler reply: @escaping (FSDirectoryVerifier, (any Error)?) -> Void
    ) {
        guard let dirItem = directory as? OpenDriveFSItem else {
            reply(FSDirectoryVerifier.initial, POSIXError(.ENOTDIR))
            return
        }
        Task {
            do {
                let children = try await driveVolume.listDirectory(itemId: dirItem.itemId)
                let startIndex = Int(cookie.rawValue)
                if startIndex < children.count {
                    for idx in startIndex..<children.count {
                        let child = children[idx]
                        let nextCookie = FSDirectoryCookie(UInt64(idx + 1))
                        let itemType: FSItem.ItemType = child.isDirectory ? .directory : .file
                        let itemID = FSItem.Identifier(rawValue: child.itemId) ?? .invalid
                        let entryAttrs = attributes != nil ? buildAttributes(for: child) : nil

                        let packed = packer.packEntry(
                            name: FSFileName(string: child.name),
                            itemType: itemType,
                            itemID: itemID,
                            nextCookie: nextCookie,
                            attributes: entryAttrs
                        )
                        if !packed {
                            break
                        }
                    }
                }
                let currentVerifier = FSDirectoryVerifier(UInt64(max(1, children.count)))
                reply(currentVerifier, nil)
            } catch {
                reply(FSDirectoryVerifier.initial, error)
            }
        }
    }

    // MARK: - Attributes

    public func getAttributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem,
        replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void
    ) {
        guard let fdItem = item as? OpenDriveFSItem else {
            reply(nil, POSIXError(.ENOENT))
            return
        }
        Task {
            let latestNode = await driveVolume.node(for: fdItem.itemId) ?? fdItem.vfsNode
            fdItem.vfsNode = latestNode
            reply(buildAttributes(for: latestNode), nil)
        }
    }

    public func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem,
        replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void
    ) {
        guard let fdItem = item as? OpenDriveFSItem else {
            reply(nil, POSIXError(.ENOENT))
            return
        }
        Task {
            let latestNode = await driveVolume.node(for: fdItem.itemId) ?? fdItem.vfsNode
            reply(buildAttributes(for: latestNode), nil)
        }
    }

    // MARK: - Create, Rename, Remove, Symlinks

    public func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        guard let dirItem = directory as? OpenDriveFSItem,
              let nameStr = name.string else {
            reply(nil, nil, POSIXError(.EINVAL))
            return
        }
        let isDir = (type == .directory)
        Task {
            do {
                let createdNode = try await driveVolume.createItem(
                    name: nameStr,
                    isDirectory: isDir,
                    inDirectory: dirItem.itemId
                )
                let fsItem = internFSItem(for: createdNode)
                reply(fsItem, FSFileName(string: createdNode.name), nil)
            } catch {
                reply(nil, nil, error)
            }
        }
    }

    public func createSymbolicLink(
        named name: FSFileName,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName,
        replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        reply(nil, nil, POSIXError(.ENOTSUP))
    }

    public func createLink(
        to item: FSItem,
        named name: FSFileName,
        inDirectory directory: FSItem,
        replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void
    ) {
        reply(nil, POSIXError(.ENOTSUP))
    }

    public func readSymbolicLink(
        _ item: FSItem,
        replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void
    ) {
        reply(nil, POSIXError(.ENOTSUP))
    }

    public func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?,
        replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void
    ) {
        guard let fdItem = item as? OpenDriveFSItem,
              let destDir = destinationDirectory as? OpenDriveFSItem,
              let newNameStr = destinationName.string else {
            reply(nil, POSIXError(.EINVAL))
            return
        }
        Task {
            do {
                if let over = overItem as? OpenDriveFSItem {
                    try? await driveVolume.removeItem(itemId: over.itemId)
                }
                let updated = try await driveVolume.renameItem(
                    itemId: fdItem.itemId,
                    toNewName: newNameStr,
                    inDestinationDirectory: destDir.itemId
                )
                fdItem.vfsNode = updated
                reply(FSFileName(string: updated.name), nil)
            } catch {
                reply(nil, error)
            }
        }
    }

    public func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        fromDirectory directory: FSItem,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        guard let fdItem = item as? OpenDriveFSItem else {
            reply(POSIXError(.ENOENT))
            return
        }
        Task {
            do {
                try await driveVolume.removeItem(itemId: fdItem.itemId)
                reply(nil)
            } catch {
                reply(error)
            }
        }
    }

    // MARK: - Open, Close, Read, Write

    public func openItem(
        _ item: FSItem,
        modes: FSVolume.OpenModes,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        reply(nil)
    }

    public func closeItem(
        _ item: FSItem,
        modes: FSVolume.OpenModes,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        guard let fdItem = item as? OpenDriveFSItem else {
            reply(nil)
            return
        }
        Task {
            try? await driveVolume.closeAndCommitIfDirty(itemId: fdItem.itemId)
            reply(nil)
        }
    }

    public func read(
        from item: FSItem,
        at offset: off_t,
        length: Int,
        into buffer: FSMutableFileDataBuffer,
        replyHandler reply: @escaping (Int, (any Error)?) -> Void
    ) {
        guard let fdItem = item as? OpenDriveFSItem else {
            reply(0, POSIXError(.ENOENT))
            return
        }
        Task {
            do {
                let data = try await driveVolume.read(itemId: fdItem.itemId, offset: offset, length: length)
                let copiedCount = buffer.withUnsafeMutableBytes { rawDest -> Int in
                    let count = min(data.count, rawDest.count)
                    guard count > 0, let base = rawDest.baseAddress else { return 0 }
                    data.copyBytes(to: base.assumingMemoryBound(to: UInt8.self), count: count)
                    return count
                }
                reply(copiedCount, nil)
            } catch {
                reply(0, error)
            }
        }
    }

    public func write(
        contents: Data,
        to item: FSItem,
        at offset: off_t,
        replyHandler reply: @escaping (Int, (any Error)?) -> Void
    ) {
        guard let fdItem = item as? OpenDriveFSItem else {
            reply(0, POSIXError(.ENOENT))
            return
        }
        Task {
            do {
                let written = try await driveVolume.write(itemId: fdItem.itemId, offset: offset, data: contents)
                reply(written, nil)
            } catch {
                reply(0, error)
            }
        }
    }

    // MARK: - Extended Attributes (`FSVolume.XattrOperations`) & Access Check

    public func getXattr(
        named name: FSFileName,
        of item: FSItem,
        replyHandler reply: @escaping (Data?, (any Error)?) -> Void
    ) {
        guard let fdItem = item as? OpenDriveFSItem,
              let key = name.string,
              let val = fdItem.getXattr(named: key) else {
            reply(nil, POSIXError(.ENOATTR))
            return
        }
        reply(val, nil)
    }

    public func setXattr(
        named name: FSFileName,
        to value: Data?,
        on item: FSItem,
        policy: FSVolume.SetXattrPolicy,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        guard let fdItem = item as? OpenDriveFSItem,
              let key = name.string else {
            reply(POSIXError(.EINVAL))
            return
        }
        if policy == .delete {
            fdItem.setXattr(named: key, data: nil)
        } else {
            fdItem.setXattr(named: key, data: value)
        }
        reply(nil)
    }

    public func listXattrs(
        of item: FSItem,
        replyHandler reply: @escaping ([FSFileName]?, (any Error)?) -> Void
    ) {
        guard let fdItem = item as? OpenDriveFSItem else {
            reply([], nil)
            return
        }
        let names = fdItem.listXattrNames().map { FSFileName(string: $0) }
        reply(names, nil)
    }

    public func checkAccess(
        to theItem: FSItem,
        requestedAccess access: FSVolume.AccessMask,
        replyHandler reply: @escaping (Bool, (any Error)?) -> Void
    ) {
        reply(true, nil)
    }

    // MARK: - Internal Item & Attribute Helpers

    private func internFSItem(for node: DriveVolume.VFSNode) -> OpenDriveFSItem {
        itemsLock.lock()
        defer { itemsLock.unlock() }
        if let existing = fsItemsById[node.itemId] {
            existing.vfsNode = node
            return existing
        }
        let created = OpenDriveFSItem(node: node)
        fsItemsById[node.itemId] = created
        return created
    }

    private func buildAttributes(for node: DriveVolume.VFSNode) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.type = node.isDirectory ? .directory : .file
        attrs.mode = node.isDirectory ? UInt32(S_IFDIR | 0o755) : UInt32(S_IFREG | 0o644)
        attrs.linkCount = 1
        attrs.uid = getuid()
        attrs.gid = getgid()
        attrs.size = UInt64(max(0, node.size))
        attrs.allocSize = UInt64(max(0, node.size))
        attrs.fileID = FSItem.Identifier(rawValue: node.itemId) ?? .invalid
        attrs.parentID = FSItem.Identifier(rawValue: node.parentItemId) ?? .parentOfRoot

        let sec = Int(node.modifiedTime)
        let nsec = Int((node.modifiedTime - Double(sec)) * 1_000_000_000)
        let ts = timespec(tv_sec: sec, tv_nsec: max(0, nsec))
        attrs.modifyTime = ts
        attrs.changeTime = ts
        attrs.accessTime = ts
        attrs.birthTime = ts
        return attrs
    }
}

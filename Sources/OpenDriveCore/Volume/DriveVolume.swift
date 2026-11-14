import Foundation
import CryptoKit

/// Core virtual filesystem engine managing in-memory inode numbers (`UInt64`), local write staging (`Scratch`),
/// `.fd-refresh` triggers, and bridging POSIX/FSKit operations to `MetadataStore`, `RangeReader`, `UploadEngine`, and `SyncEngine`.
public actor DriveVolume {
    public enum NodeKind: Sendable, Equatable {
        case root
        case cloudRoot(accountId: String)
        case remote(accountId: String, driveId: String)
        case scratch(accountId: String, tempId: String)
        case refreshTrigger
    }

    public struct VFSNode: Sendable, Equatable {
        public let itemId: UInt64
        public var parentItemId: UInt64
        public var kind: NodeKind
        public var name: String
        public var isDirectory: Bool
        public var size: Int64
        public var modifiedTime: Double

        public init(
            itemId: UInt64,
            parentItemId: UInt64,
            kind: NodeKind,
            name: String,
            isDirectory: Bool,
            size: Int64,
            modifiedTime: Double = Date().timeIntervalSince1970
        ) {
            self.itemId = itemId
            self.parentItemId = parentItemId
            self.kind = kind
            self.name = name
            self.isDirectory = isDirectory
            self.size = size
            self.modifiedTime = modifiedTime
        }
    }

    public struct ScratchBuffer: Sendable {
        public let tempId: String
        public let accountId: String
        public var parentDriveId: String
        public var targetDriveId: String?
        public var name: String
        public let localURL: URL
        public var size: Int64
        public var dirty: Bool
        public var openCount: Int
        public var baseVersion: String?
        public var baseHash: String?
    }

    public struct MountedCloudStack: Sendable {
        public var account: CloudAccount
        public let store: MetadataStore
        public let client: any CloudDrive
        public let reader: RangeReader
        public let uploader: UploadEngine
        public let syncer: SyncEngine
        public var masterKey: SymmetricKey?

        public init(
            account: CloudAccount,
            store: MetadataStore,
            client: any CloudDrive,
            reader: RangeReader,
            uploader: UploadEngine,
            syncer: SyncEngine,
            masterKey: SymmetricKey? = nil
        ) {
            self.account = account
            self.store = store
            self.client = client
            self.reader = reader
            self.uploader = uploader
            self.syncer = syncer
            self.masterKey = masterKey
        }
    }

    public static let rootItemId: UInt64 = 2 // Matches FSItem.Identifier.rootDirectory.rawValue

    private var nextInodeNumber: UInt64 = 100
    private var nodesById: [UInt64: VFSNode] = [:]
    private var inodeByDriveKey: [String: UInt64] = [:]
    private var scratchesById: [UInt64: ScratchBuffer] = [:]
    private var stacksByAccountId: [String: MountedCloudStack] = [:]
    private var syncLoopTask: Task<Void, Never>?
    private let scratchDirectory: URL

    public init(scratchDirectory: URL = OpenDrivePaths.scratchCacheURL) throws {
        self.scratchDirectory = scratchDirectory
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)

        let rootNode = VFSNode(
            itemId: Self.rootItemId,
            parentItemId: 1, // FSItem.Identifier.parentOfRoot
            kind: .root,
            name: "Open Drive",
            isDirectory: true,
            size: 0
        )
        self.nodesById[Self.rootItemId] = rootNode
    }

    // MARK: - Cloud Stack Registration

    public func registerCloudStack(_ stack: MountedCloudStack) {
        stacksByAccountId[stack.account.id] = stack
        let key = "cloudRoot:\(stack.account.id)"
        let inode = inodeByDriveKey[key] ?? allocateInode(forKey: key)
        let node = VFSNode(
            itemId: inode,
            parentItemId: Self.rootItemId,
            kind: .cloudRoot(accountId: stack.account.id),
            name: stack.account.displayName,
            isDirectory: true,
            size: 0,
            modifiedTime: stack.account.rootCreatedAt ?? Date().timeIntervalSince1970
        )
        nodesById[inode] = node
    }

    public func unregisterRemovedAccounts(keepingIds: Set<String>) {
        let removedIds = Set(stacksByAccountId.keys).subtracting(keepingIds)
        for accountId in removedIds {
            stacksByAccountId.removeValue(forKey: accountId)
            let key = "cloudRoot:\(accountId)"
            if let inode = inodeByDriveKey.removeValue(forKey: key) {
                nodesById.removeValue(forKey: inode)
            }
        }
    }

    public func syncAllAccountsOnce() async {
        for stack in stacksByAccountId.values {
            let masterKey = stack.masterKey
            _ = try? await stack.syncer.pullRemoteChanges(masterKey: masterKey)
            await stack.uploader.processQueue(masterKey: masterKey)
        }
    }

    public func startBackgroundSyncLoop(intervalSeconds: Double = 30.0) {
        syncLoopTask?.cancel()
        syncLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncAllAccountsOnce()
                let nanos = UInt64(max(5.0, intervalSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    public func stopBackgroundSyncLoop() {
        syncLoopTask?.cancel()
        syncLoopTask = nil
    }

    public func setNetworkStateForAll(isMetered: Bool, isOffline: Bool) async {
        for stack in stacksByAccountId.values {
            await stack.uploader.setNetworkState(isMetered: isMetered, isOffline: isOffline)
            if !isOffline && !isMetered {
                let mk = stack.masterKey
                await stack.uploader.processQueue(masterKey: mk)
            }
        }
    }

    public func setBandwidthModeForAll(_ mode: BandwidthMode) async {
        for stack in stacksByAccountId.values {
            await stack.uploader.setBandwidthMode(mode)
        }
    }

    public func setPauseOnMeteredForAll(_ enabled: Bool) async {
        for stack in stacksByAccountId.values {
            await stack.uploader.setPauseOnMetered(enabled)
        }
    }

    public func rootNode() -> VFSNode {
        nodesById[Self.rootItemId]!
    }

    public func node(for itemId: UInt64) -> VFSNode? {
        nodesById[itemId]
    }

    // MARK: - Directory Enumeration & Lookup

    public func listDirectory(itemId: UInt64) async throws -> [VFSNode] {
        guard let dirNode = nodesById[itemId] else {
            throw POSIXError(.ENOENT)
        }

        switch dirNode.kind {
        case .root:
            return stacksByAccountId.values.compactMap { stack in
                let key = "cloudRoot:\(stack.account.id)"
                guard let inode = inodeByDriveKey[key] else { return nil }
                return nodesById[inode]
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        case .cloudRoot(let accountId):
            guard let stack = stacksByAccountId[accountId] else { throw POSIXError(.ENOENT) }
            let rootDriveId = stack.account.rootId ?? "root"
            return try await listRemoteParent(accountId: accountId, parentDriveId: rootDriveId, parentInode: itemId)

        case .remote(let accountId, let driveId):
            return try await listRemoteParent(accountId: accountId, parentDriveId: driveId, parentInode: itemId)

        default:
            throw POSIXError(.ENOTDIR)
        }
    }

    public func lookup(name: String, inDirectory itemId: UInt64) async throws -> VFSNode {
        if name == OpenDrivePaths.refreshTriggerFileName {
            // Touching or looking up `.fd-refresh` triggers background delta sync across all clouds
            for stack in stacksByAccountId.values {
                let masterKey = stack.masterKey
                Task {
                    _ = try? await stack.syncer.pullRemoteChanges(masterKey: masterKey)
                }
            }
            let triggerInode = allocateInode(forKey: "virtual:.fd-refresh")
            let triggerNode = VFSNode(
                itemId: triggerInode,
                parentItemId: itemId,
                kind: .refreshTrigger,
                name: OpenDrivePaths.refreshTriggerFileName,
                isDirectory: false,
                size: 0
            )
            nodesById[triggerInode] = triggerNode
            return triggerNode
        }

        let children = try await listDirectory(itemId: itemId)
        let foldedTarget = MetadataStore.fold(name)
        if let match = children.first(where: { MetadataStore.fold($0.name) == foldedTarget }) {
            return match
        }
        throw POSIXError(.ENOENT)
    }

    // MARK: - File / Directory Creation, Write Staging (`Scratch`), and Close Commit

    public func createItem(
        name: String,
        isDirectory: Bool,
        inDirectory parentItemId: UInt64
    ) async throws -> VFSNode {
        guard let parentNode = nodesById[parentItemId] else {
            throw POSIXError(.ENOENT)
        }
        let (accountId, parentDriveId) = try resolveParentDriveContext(for: parentNode)
        guard let stack = stacksByAccountId[accountId] else {
            throw POSIXError(.ENOENT)
        }

        // Reject duplicate name in same directory
        if (try? await lookup(name: name, inDirectory: parentItemId)) != nil {
            throw POSIXError(.EEXIST)
        }

        // Record parent directory in recentFolders for quick Menu-Bar Drag & Drop access
        try? await stack.store.recordRecentFolder(id: parentDriveId, name: parentNode.name)

        if isDirectory {
            let remoteName: String
            if stack.account.encryptionEnabled, let mk = stack.masterKey {
                remoteName = try VaultCrypto.encryptFilename(name, masterKey: mk)
            } else {
                remoteName = name
            }
            var created = try await stack.client.createFolder(
                name: remoteName,
                parentId: parentDriveId,
                isEncrypted: stack.account.encryptionEnabled,
                origClearName: name
            )
            created.name = name
            try await stack.store.upsertItem(created)
            return registerDriveItemNode(created, accountId: accountId, parentInode: parentItemId)
        } else {
            // Stage new regular file in local scratch until closed
            let tempId = UUID().uuidString
            let scratchURL = scratchDirectory.appendingPathComponent("\(tempId).scratch")
            FileManager.default.createFile(atPath: scratchURL.path, contents: Data())

            let inode = allocateInode(forKey: "scratch:\(accountId):\(tempId)")
            let scratch = ScratchBuffer(
                tempId: tempId,
                accountId: accountId,
                parentDriveId: parentDriveId,
                targetDriveId: nil,
                name: name,
                localURL: scratchURL,
                size: 0,
                dirty: true,
                openCount: 1,
                baseVersion: nil,
                baseHash: nil
            )
            scratchesById[inode] = scratch
            let vfsNode = VFSNode(
                itemId: inode,
                parentItemId: parentItemId,
                kind: .scratch(accountId: accountId, tempId: tempId),
                name: name,
                isDirectory: false,
                size: 0
            )
            nodesById[inode] = vfsNode
            return vfsNode
        }
    }

    public func read(itemId: UInt64, offset: Int64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        if let scratch = scratchesById[itemId] {
            let handle = try FileHandle(forReadingFrom: scratch.localURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(max(0, offset)))
            return try handle.read(upToCount: length) ?? Data()
        }

        guard let node = nodesById[itemId] else {
            throw POSIXError(.ENOENT)
        }
        guard case .remote(let accountId, let driveId) = node.kind,
              let stack = stacksByAccountId[accountId],
              let item = try await stack.store.fetchItem(driveId: driveId) else {
            return Data()
        }
        try? await stack.store.markOpened(driveId: driveId)
        return try await stack.reader.readRange(
            item: item,
            offset: offset,
            length: length,
            masterKey: stack.masterKey
        )
    }

    @discardableResult
    public func write(itemId: UInt64, offset: Int64, data: Data) async throws -> Int {
        guard let node = nodesById[itemId] else {
            throw POSIXError(.ENOENT)
        }

        // If writing to a remote file for the first time, materialize a local scratch buffer
        if scratchesById[itemId] == nil {
            guard case .remote(let accountId, let driveId) = node.kind,
                  let stack = stacksByAccountId[accountId],
                  let item = try await stack.store.fetchItem(driveId: driveId) else {
                throw POSIXError(.EROFS)
            }
            let tempId = UUID().uuidString
            let scratchURL = scratchDirectory.appendingPathComponent("\(tempId).scratch")
            if item.size > 0 {
                let existingBytes = try await stack.reader.readRange(
                    item: item,
                    offset: 0,
                    length: Int(item.size),
                    masterKey: stack.masterKey
                )
                try existingBytes.write(to: scratchURL, options: .atomic)
            } else {
                FileManager.default.createFile(atPath: scratchURL.path, contents: Data())
            }
            scratchesById[itemId] = ScratchBuffer(
                tempId: tempId,
                accountId: accountId,
                parentDriveId: item.parentId ?? (stack.account.rootId ?? "root"),
                targetDriveId: item.driveId,
                name: item.name,
                localURL: scratchURL,
                size: item.size,
                dirty: true,
                openCount: 1,
                baseVersion: item.version,
                baseHash: item.md5
            )
        }

        guard var scratch = scratchesById[itemId] else {
            throw POSIXError(.EIO)
        }
        let handle = try FileHandle(forUpdating: scratch.localURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, offset)))
        try handle.write(contentsOf: data)

        let endOffset = offset + Int64(data.count)
        scratch.size = max(scratch.size, endOffset)
        scratch.dirty = true
        scratchesById[itemId] = scratch

        if var updatedNode = nodesById[itemId] {
            updatedNode.size = scratch.size
            updatedNode.modifiedTime = Date().timeIntervalSince1970
            nodesById[itemId] = updatedNode
        }
        return data.count
    }

    public func closeAndCommitIfDirty(itemId: UInt64) async throws {
        guard var scratch = scratchesById[itemId], scratch.dirty else { return }
        scratch.dirty = false
        scratchesById[itemId] = scratch

        guard let stack = stacksByAccountId[scratch.accountId] else { return }
        _ = try await stack.uploader.enqueueUpload(
            localURL: scratch.localURL,
            parentId: scratch.parentDriveId,
            targetDriveId: scratch.targetDriveId,
            name: scratch.name,
            baseVersion: scratch.baseVersion,
            baseHash: scratch.baseHash,
            encrypt: stack.account.encryptionEnabled
        )
        let masterKey = stack.masterKey
        await stack.uploader.processQueue(masterKey: masterKey)

        // If upload finished and produced a remote item, transition scratch node to remote node
        if let parentNode = nodesById[itemId]?.parentItemId,
           let parentInfo = nodesById[parentNode],
           let (_, parentDriveId) = try? resolveParentDriveContext(for: parentInfo),
           let committed = try await stack.store.lookupChild(parentId: parentDriveId, name: scratch.name) {
            scratchesById.removeValue(forKey: itemId)
            try? FileManager.default.removeItem(at: scratch.localURL)
            let updated = VFSNode(
                itemId: itemId,
                parentItemId: parentNode,
                kind: .remote(accountId: scratch.accountId, driveId: committed.driveId),
                name: committed.shownAs,
                isDirectory: committed.isFolder,
                size: committed.size,
                modifiedTime: committed.modifiedTime
            )
            nodesById[itemId] = updated
            inodeByDriveKey["remote:\(scratch.accountId):\(committed.driveId)"] = itemId
        }
    }

    public func renameItem(
        itemId: UInt64,
        toNewName newName: String,
        inDestinationDirectory destParentItemId: UInt64
    ) async throws -> VFSNode {
        guard var node = nodesById[itemId],
              let destParentNode = nodesById[destParentItemId] else {
            throw POSIXError(.ENOENT)
        }
        let (destAccountId, destParentDriveId) = try resolveParentDriveContext(for: destParentNode)
        guard let stack = stacksByAccountId[destAccountId] else {
            throw POSIXError(.EXDEV)
        }

        switch node.kind {
        case .remote(let accountId, let driveId):
            guard accountId == destAccountId else { throw POSIXError(.EXDEV) }
            let existing = try await stack.store.fetchItem(driveId: driveId)
            let oldParentDriveId = existing?.parentId
            let wireName: String
            if stack.account.encryptionEnabled, let mk = stack.masterKey {
                wireName = try VaultCrypto.encryptFilename(newName, masterKey: mk)
            } else {
                wireName = newName
            }
            var updatedItem = try await stack.client.renameOrMove(
                driveId: driveId,
                newName: wireName,
                addParentId: destParentDriveId != oldParentDriveId ? destParentDriveId : nil,
                removeParentId: destParentDriveId != oldParentDriveId ? oldParentDriveId : nil
            )
            updatedItem.name = newName
            updatedItem.parentId = destParentDriveId
            try await stack.store.upsertItem(updatedItem)
            node.name = updatedItem.shownAs
            node.parentItemId = destParentItemId
            nodesById[itemId] = node
            return node

        case .scratch(let accountId, _):
            guard accountId == destAccountId else { throw POSIXError(.EXDEV) }
            if var scratch = scratchesById[itemId] {
                scratch.name = newName
                scratch.parentDriveId = destParentDriveId
                scratchesById[itemId] = scratch
            }
            node.name = newName
            node.parentItemId = destParentItemId
            nodesById[itemId] = node
            return node

        default:
            throw POSIXError(.EPERM)
        }
    }

    public func removeItem(itemId: UInt64) async throws {
        guard let node = nodesById[itemId] else {
            throw POSIXError(.ENOENT)
        }
        switch node.kind {
        case .remote(let accountId, let driveId):
            guard let stack = stacksByAccountId[accountId] else { throw POSIXError(.ENOENT) }
            let current = try await stack.store.fetchItem(driveId: driveId)
            try await stack.client.moveToTrash(
                driveId: driveId,
                trashFolderId: stack.account.trashId,
                currentParentId: current?.parentId
            )
            try await stack.store.deleteItem(driveId: driveId)
            nodesById.removeValue(forKey: itemId)

        case .scratch:
            if let scratch = scratchesById.removeValue(forKey: itemId) {
                try? FileManager.default.removeItem(at: scratch.localURL)
            }
            nodesById.removeValue(forKey: itemId)

        default:
            throw POSIXError(.EPERM)
        }
    }

    // MARK: - Private Helpers

    private func listRemoteParent(
        accountId: String,
        parentDriveId: String,
        parentInode: UInt64
    ) async throws -> [VFSNode] {
        guard let stack = stacksByAccountId[accountId] else { return [] }
        var dbChildren = try await stack.store.listChildren(parentId: parentDriveId)
        if dbChildren.isEmpty {
            // On-demand hydration (`PartialListing`) when browsing an uncached remote folder
            if let hydrated = try? await stack.syncer.hydrateFolderIfNeeded(
                folderId: parentDriveId,
                masterKey: stack.masterKey
            ) {
                dbChildren = hydrated
            }
        }
        var result: [VFSNode] = dbChildren.map { item in
            registerDriveItemNode(item, accountId: accountId, parentInode: parentInode)
        }

        // Include any uncommitted scratch files in this directory
        for (inode, scratch) in scratchesById where scratch.accountId == accountId && scratch.parentDriveId == parentDriveId && scratch.targetDriveId == nil {
            if let scratchNode = nodesById[inode] {
                result.append(scratchNode)
            }
        }
        return result
    }

    private func registerDriveItemNode(_ item: DriveItem, accountId: String, parentInode: UInt64) -> VFSNode {
        let key = "remote:\(accountId):\(item.driveId)"
        let inode = inodeByDriveKey[key] ?? allocateInode(forKey: key)
        let size = scratchesById[inode]?.size ?? item.size
        let node = VFSNode(
            itemId: inode,
            parentItemId: parentInode,
            kind: .remote(accountId: accountId, driveId: item.driveId),
            name: item.shownAs,
            isDirectory: item.isFolder,
            size: size,
            modifiedTime: item.modifiedTime
        )
        nodesById[inode] = node
        return node
    }

    private func resolveParentDriveContext(for dirNode: VFSNode) throws -> (accountId: String, driveId: String) {
        switch dirNode.kind {
        case .cloudRoot(let accountId):
            guard let stack = stacksByAccountId[accountId] else { throw POSIXError(.ENOENT) }
            return (accountId, stack.account.rootId ?? "root")
        case .remote(let accountId, let driveId):
            guard dirNode.isDirectory else { throw POSIXError(.ENOTDIR) }
            return (accountId, driveId)
        default:
            throw POSIXError(.EPERM)
        }
    }

    private func allocateInode(forKey key: String) -> UInt64 {
        if let existing = inodeByDriveKey[key] {
            return existing
        }
        let assigned = nextInodeNumber
        nextInodeNumber += 1
        inodeByDriveKey[key] = assigned
        return assigned
    }
}

import Foundation
import CryptoKit
import Security

/// Core virtual filesystem engine managing in-memory inode numbers (`UInt64`), local write staging (`Scratch`),
/// `.od-refresh` triggers, and bridging POSIX/FSKit operations to `MetadataStore`, `RangeReader`, `UploadEngine`, and `SyncEngine`.
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
        public var posixMode: UInt32?
        public var symlinkTarget: String?

        public var isSymlink: Bool {
            symlinkTarget != nil
        }

        public init(
            itemId: UInt64,
            parentItemId: UInt64,
            kind: NodeKind,
            name: String,
            isDirectory: Bool,
            size: Int64,
            modifiedTime: Double = Date().timeIntervalSince1970,
            posixMode: UInt32? = nil,
            symlinkTarget: String? = nil
        ) {
            self.itemId = itemId
            self.parentItemId = parentItemId
            self.kind = kind
            self.name = name
            self.isDirectory = isDirectory
            self.size = size
            self.modifiedTime = modifiedTime
            self.posixMode = posixMode
            self.symlinkTarget = symlinkTarget
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
        public var generation: UInt64 = 1
        public var activeUploadId: String? = nil
        public var posixMode: UInt32? = nil
    }

    public struct MountedCloudStack: Sendable {
        public var account: CloudAccount
        public let store: MetadataStore
        public let client: any CloudDrive
        public let reader: RangeReader
        public let uploader: UploadEngine
        public let syncer: SyncEngine
        public let cache: ChunkCache?
        public var masterKey: SymmetricKey?

        public init(
            account: CloudAccount,
            store: MetadataStore,
            client: any CloudDrive,
            reader: RangeReader,
            uploader: UploadEngine,
            syncer: SyncEngine,
            cache: ChunkCache? = nil,
            masterKey: SymmetricKey? = nil
        ) {
            self.account = account
            self.store = store
            self.client = client
            self.reader = reader
            self.uploader = uploader
            self.syncer = syncer
            self.cache = cache
            self.masterKey = masterKey
        }
    }

    public struct BridgeItem: Codable, Sendable, Equatable {
        public let id: String
        public let parentId: String
        public let name: String
        public let isFolder: Bool
        public let size: Int64
        public let modifiedTime: Double
        public let versionToken: String
        public let quotaLabel: String?

        public init(
            id: String,
            parentId: String,
            name: String,
            isFolder: Bool,
            size: Int64,
            modifiedTime: Double,
            versionToken: String,
            quotaLabel: String? = nil
        ) {
            self.id = id
            self.parentId = parentId
            self.name = name
            self.isFolder = isFolder
            self.size = size
            self.modifiedTime = modifiedTime
            self.versionToken = versionToken
            self.quotaLabel = quotaLabel
        }
    }

    public static let rootItemId: UInt64 = 2 // Matches FSItem.Identifier.rootDirectory.rawValue

    private var nextInodeNumber: UInt64 = 100
    private var nodesById: [UInt64: VFSNode] = [:]
    private var inodeByDriveKey: [String: UInt64] = [:]
    private var scratchesById: [UInt64: ScratchBuffer] = [:]
    private var stacksByAccountId: [String: MountedCloudStack] = [:]
    private var quotaByAccountId: [String: CloudStorageQuota] = [:]
    private var backgroundUploadTasks: [String: Task<Void, Never>] = [:]
    private var syncLoopTask: Task<Void, Never>?
    private var isNetworkOffline: Bool = false
    private var isNetworkMetered: Bool = false
    private var bridgeSyncEpoch: Int64 = 1
    private let scratchDirectory: URL
    private let flattenSingleAccountRoot: Bool

    public init(
        scratchDirectory: URL = OpenDrivePaths.scratchCacheURL,
        flattenSingleAccountRoot: Bool = true,
        rootName: String = OpenDrivePaths.defaultDriveName
    ) throws {
        self.scratchDirectory = scratchDirectory
        self.flattenSingleAccountRoot = flattenSingleAccountRoot
        try OpenDrivePaths.createPrivateDirectory(at: scratchDirectory)

        let rootNode = VFSNode(
            itemId: Self.rootItemId,
            parentItemId: 1, // FSItem.Identifier.parentOfRoot
            kind: .root,
            name: rootName,
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
        bridgeSyncEpoch += 1
    }

    public func unregisterRemovedAccounts(keepingIds: Set<String>) {
        let removedIds = Set(stacksByAccountId.keys).subtracting(keepingIds)
        for accountId in removedIds {
            stacksByAccountId.removeValue(forKey: accountId)
            quotaByAccountId.removeValue(forKey: accountId)
            let key = "cloudRoot:\(accountId)"
            if let inode = inodeByDriveKey.removeValue(forKey: key) {
                nodesById.removeValue(forKey: inode)
            }
        }
        if !removedIds.isEmpty {
            bridgeSyncEpoch += 1
        }
    }

    public func syncAllAccountsOnce() async {
        var totalPulled = 0
        for stack in stacksByAccountId.values {
            let masterKey = stack.masterKey
            if let pulled = try? await stack.syncer.pullRemoteChanges(masterKey: masterKey) {
                totalPulled += pulled
            }
            await stack.uploader.processQueue(masterKey: masterKey)
            await reconcileCompletedScratches(for: stack)
        }
        if totalPulled > 0 {
            bridgeSyncEpoch += 1
        }
        await warmPinnedItems()
        await refreshStorageQuotas()
    }

    public func refreshStorageQuotas() async {
        let previousLabel = finderQuotaLabel()
        for (accountId, stack) in stacksByAccountId {
            if let quota = try? await stack.client.fetchStorageQuota() {
                quotaByAccountId[accountId] = quota
            }
        }
        if finderQuotaLabel() != previousLabel {
            bridgeSyncEpoch += 1
        }
    }

    private func finderQuotaLabel(forAccountId accountId: String? = nil) -> String? {
        if let resolvedAccountId = accountId ?? singleFlattenedStack?.account.id {
            guard let quota = quotaByAccountId[resolvedAccountId] else {
                return nil
            }
            if let available = quota.availableBytes {
                let formatted = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
                return "\(formatted) available on Google Drive"
            }
            return "Unlimited storage on Google Drive"
        }
        guard !quotaByAccountId.isEmpty else { return nil }
        if let agg = aggregatedStorageQuota() {
            let clamped = Int64(min(agg.availableBytes, UInt64(Int64.max)))
            let formatted = ByteCountFormatter.string(fromByteCount: clamped, countStyle: .file)
            return "\(formatted) available on Google Drive"
        }
        return "Unlimited storage on Google Drive"
    }

    public func aggregatedStorageQuota() -> (totalBytes: UInt64, usedBytes: UInt64, availableBytes: UInt64)? {
        var totalLimit: UInt64 = 0
        var totalUsage: UInt64 = 0
        var hasFiniteQuota = false

        for quota in quotaByAccountId.values {
            guard let limit = quota.limit, limit > 0 else { continue }
            hasFiniteQuota = true
            totalLimit += UInt64(limit)
            totalUsage += UInt64(max(0, quota.usage ?? 0))
        }

        guard hasFiniteQuota, totalLimit > 0 else { return nil }
        let used = min(totalUsage, totalLimit)
        return (totalBytes: totalLimit, usedBytes: used, availableBytes: totalLimit - used)
    }

    public func warmPinnedItems() async {
        guard !isNetworkOffline && !isNetworkMetered else { return }
        for stack in stacksByAccountId.values {
            guard let pinnedItems = try? await stack.store.fetchPinnedItems() else { continue }
            let chunkSize = await stack.reader.configuredChunkSize
            guard chunkSize > 0 else { continue }

            for item in pinnedItems where item.size > 0 {
                if item.isEncrypted && stack.masterKey == nil {
                    continue
                }
                let totalChunks = Int((item.size + Int64(chunkSize) - 1) / Int64(chunkSize))
                for idx in 0..<totalChunks {
                    let cached = await stack.reader.isChunkCached(item: item, chunkIndex: idx)
                    if !cached {
                        let offset = Int64(idx) * Int64(chunkSize)
                        _ = try? await stack.reader.readRange(
                            item: item,
                            offset: offset,
                            length: chunkSize,
                            masterKey: stack.masterKey
                        )
                    }
                }
            }
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
        self.isNetworkMetered = isMetered
        self.isNetworkOffline = isOffline
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

    private var singleFlattenedStack: MountedCloudStack? {
        flattenSingleAccountRoot && stacksByAccountId.count == 1 ? stacksByAccountId.values.first : nil
    }

    public func allowsDirectRootMutations() -> Bool {
        singleFlattenedStack != nil
    }

    // MARK: - Directory Enumeration & Lookup

    public func listDirectory(itemId: UInt64) async throws -> [VFSNode] {
        guard let dirNode = nodesById[itemId] else {
            throw POSIXError(.ENOENT)
        }

        switch dirNode.kind {
        case .root:
            if let stack = singleFlattenedStack {
                return try await listRemoteParent(
                    accountId: stack.account.id,
                    parentDriveId: stack.account.rootId ?? "root",
                    parentInode: Self.rootItemId
                )
            }
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
            // Touching or looking up `.od-refresh` triggers background delta sync across all clouds
            for stack in stacksByAccountId.values {
                let masterKey = stack.masterKey
                Task {
                    _ = try? await stack.syncer.pullRemoteChanges(masterKey: masterKey)
                }
            }
            let triggerInode = allocateInode(forKey: "virtual:.od-refresh")
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

        if stack.account.encryptionEnabled && stack.masterKey == nil {
            throw POSIXError(.EACCES)
        }

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
                origClearName: stack.account.encryptionEnabled ? nil : name
            )
            created.name = name
            try await stack.store.upsertItem(created)
            return registerDriveItemNode(created, accountId: accountId, parentInode: parentItemId)
        } else {
            // Stage new regular file in local scratch until closed
            let tempId = UUID().uuidString
            let scratchURL = scratchDirectory.appendingPathComponent("\(tempId).scratch")
            FileManager.default.createFile(
                atPath: scratchURL.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            )
            OpenDrivePaths.setPrivateFilePermissions(at: scratchURL)

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

    public func createSymlink(
        name: String,
        target: String,
        inDirectory parentItemId: UInt64
    ) async throws -> VFSNode {
        guard let parentNode = nodesById[parentItemId] else {
            throw POSIXError(.ENOENT)
        }
        let (accountId, parentDriveId) = try resolveParentDriveContext(for: parentNode)
        guard let stack = stacksByAccountId[accountId] else {
            throw POSIXError(.ENOENT)
        }

        if (try? await lookup(name: name, inDirectory: parentItemId)) != nil {
            throw POSIXError(.EEXIST)
        }

        if stack.account.encryptionEnabled && stack.masterKey == nil {
            throw POSIXError(.EACCES)
        }

        let remoteName: String
        let wireTarget: String
        if stack.account.encryptionEnabled, let mk = stack.masterKey {
            remoteName = try VaultCrypto.encryptFilename(name, masterKey: mk)
            wireTarget = try VaultCrypto.encryptSymlinkTarget(target, masterKey: mk)
        } else {
            remoteName = name
            wireTarget = target
        }

        var created = try await stack.client.createSymlink(
            name: remoteName,
            target: wireTarget,
            parentId: parentDriveId,
            isEncrypted: stack.account.encryptionEnabled,
            origClearName: stack.account.encryptionEnabled ? nil : name
        )
        created.name = name
        created.symlinkTarget = target
        created.size = Int64(target.utf8.count)
        created.posixMode = created.posixMode ?? 0o777
        try await stack.store.upsertItem(created)
        try? await stack.store.recordLocalChange(driveId: created.driveId)
        return registerDriveItemNode(created, accountId: accountId, parentInode: parentItemId)
    }

    public func readSymlinkTarget(itemId: UInt64) async throws -> String {
        guard var node = nodesById[itemId] else {
            throw POSIXError(.ENOENT)
        }
        if let target = node.symlinkTarget, !target.isEmpty {
            return target
        }
        guard case .remote(let accountId, let driveId) = node.kind,
              let stack = stacksByAccountId[accountId],
              var item = try await stack.store.fetchItem(driveId: driveId),
              item.isSymlink else {
            throw POSIXError(.EINVAL)
        }
        if item.isEncrypted && stack.masterKey == nil {
            throw POSIXError(.EACCES)
        }
        if let stored = item.symlinkTarget, !stored.isEmpty {
            let resolved: String
            if item.isEncrypted, let mk = stack.masterKey,
               let decrypted = try? VaultCrypto.decryptSymlinkTarget(stored, masterKey: mk) {
                resolved = decrypted
            } else {
                resolved = stored
            }
            node.symlinkTarget = resolved
            node.size = Int64(resolved.utf8.count)
            nodesById[itemId] = node
            return resolved
        }
        let readLen = Int(min(max(item.size, 4096), 65_536))
        let decoded: String
        if item.isEncrypted {
            guard let mk = stack.masterKey else {
                throw POSIXError(.EACCES)
            }
            let rawData = try await stack.client.downloadByteRange(driveId: driveId, offset: 0, length: readLen)
            guard let encoded = String(data: rawData, encoding: .utf8), !encoded.isEmpty else {
                throw POSIXError(.EIO)
            }
            decoded = try VaultCrypto.decryptSymlinkTarget(encoded, masterKey: mk)
        } else {
            let data = try await stack.reader.readRange(
                item: item,
                offset: 0,
                length: readLen,
                masterKey: stack.masterKey
            )
            guard let plain = String(data: data, encoding: .utf8), !plain.isEmpty else {
                throw POSIXError(.EIO)
            }
            decoded = plain
        }
        item.symlinkTarget = decoded
        item.size = Int64(decoded.utf8.count)
        try? await stack.store.upsertItem(item)
        node.symlinkTarget = decoded
        node.size = item.size
        nodesById[itemId] = node
        return decoded
    }

    @discardableResult
    public func write(itemId: UInt64, offset: Int64, data: Data) async throws -> Int {
        var scratch = try await materializeScratch(for: itemId)
        let handle = try FileHandle(forUpdating: scratch.localURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, offset)))
        try handle.write(contentsOf: data)

        let endOffset = offset + Int64(data.count)
        scratch.size = max(scratch.size, endOffset)
        scratch.dirty = true
        scratch.generation &+= 1
        scratchesById[itemId] = scratch

        if var updatedNode = nodesById[itemId] {
            updatedNode.size = scratch.size
            updatedNode.modifiedTime = Date().timeIntervalSince1970
            nodesById[itemId] = updatedNode
        }
        return data.count
    }

    public func setAttributes(
        itemId: UInt64,
        newSize: Int64?,
        modifiedTime: Double?,
        posixMode: UInt32? = nil
    ) async throws -> VFSNode {
        guard var node = nodesById[itemId] else {
            throw POSIXError(.ENOENT)
        }
        if let newSize {
            guard !node.isDirectory else {
                throw POSIXError(.EISDIR)
            }
            let targetSize = max(0, newSize)
            var scratch = try await materializeScratch(for: itemId, maxHydrateBytes: targetSize)
            let handle = try FileHandle(forUpdating: scratch.localURL)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(targetSize))

            scratch.size = targetSize
            scratch.dirty = true
            scratch.generation &+= 1
            scratchesById[itemId] = scratch
            node.size = targetSize
        }
        if let modifiedTime {
            node.modifiedTime = modifiedTime
        }
        if let rawMode = posixMode {
            let perm = rawMode & 0o0777
            node.posixMode = perm
            if var scratch = scratchesById[itemId] {
                scratch.posixMode = perm
                scratchesById[itemId] = scratch
            } else if case .remote(let accountId, let driveId) = node.kind,
                      let stack = stacksByAccountId[accountId] {
                try? await stack.store.updatePosixMode(driveId: driveId, mode: perm)
                let client = stack.client
                Task {
                    try? await client.updatePosixMode(driveId: driveId, mode: perm)
                }
            }
        }
        nodesById[itemId] = node
        return node
    }

    private func materializeScratch(for itemId: UInt64, maxHydrateBytes: Int64? = nil) async throws -> ScratchBuffer {
        if let existing = scratchesById[itemId] {
            return existing
        }
        guard let node = nodesById[itemId] else {
            throw POSIXError(.ENOENT)
        }
        guard case .remote(let accountId, let driveId) = node.kind,
              let stack = stacksByAccountId[accountId],
              let item = try await stack.store.fetchItem(driveId: driveId) else {
            throw POSIXError(.EROFS)
        }

        let tempId = UUID().uuidString
        let scratchURL = scratchDirectory.appendingPathComponent("\(tempId).scratch")
        let bytesToRead = min(item.size, maxHydrateBytes ?? item.size)
        if bytesToRead > 0 {
            let existingBytes = try await stack.reader.readRange(
                item: item,
                offset: 0,
                length: Int(bytesToRead),
                masterKey: stack.masterKey
            )
            try OpenDrivePaths.writePrivateFile(existingBytes, to: scratchURL)
        } else {
            FileManager.default.createFile(
                atPath: scratchURL.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            )
            OpenDrivePaths.setPrivateFilePermissions(at: scratchURL)
        }

        let buffer = ScratchBuffer(
            tempId: tempId,
            accountId: accountId,
            parentDriveId: item.parentId ?? (stack.account.rootId ?? "root"),
            targetDriveId: item.driveId,
            name: item.name,
            localURL: scratchURL,
            size: bytesToRead,
            dirty: true,
            openCount: 1,
            baseVersion: item.version,
            baseHash: item.md5,
            posixMode: item.posixMode ?? node.posixMode
        )
        scratchesById[itemId] = buffer
        return buffer
    }

    public func closeAndCommitIfDirty(itemId: UInt64, awaitUpload: Bool = true) async throws {
        guard var scratch = scratchesById[itemId], scratch.dirty else { return }
        let previousUploadId = scratch.activeUploadId
        scratch.dirty = false
        let commitGen = scratch.generation

        guard let stack = stacksByAccountId[scratch.accountId] else {
            scratchesById[itemId] = scratch
            return
        }

        let uploadRecord = try await stack.uploader.enqueueUpload(
            localURL: scratch.localURL,
            parentId: scratch.parentDriveId,
            targetDriveId: scratch.targetDriveId,
            name: scratch.name,
            baseVersion: scratch.baseVersion,
            baseHash: scratch.baseHash,
            encrypt: stack.account.encryptionEnabled
        )
        scratch.activeUploadId = uploadRecord.id
        scratchesById[itemId] = scratch

        let masterKey = stack.masterKey
        let previousTask = previousUploadId.flatMap { backgroundUploadTasks[$0] }

        if awaitUpload {
            await previousTask?.value
            await stack.uploader.processQueue(masterKey: masterKey)
            await finalizeCommittedScratch(
                itemId: itemId,
                expectedGeneration: commitGen,
                uploadId: uploadRecord.id
            )
        } else {
            let uploadId = uploadRecord.id
            let task = Task { [weak self] in
                await previousTask?.value
                await stack.uploader.processQueue(masterKey: masterKey)
                await self?.finalizeCommittedScratch(
                    itemId: itemId,
                    expectedGeneration: commitGen,
                    uploadId: uploadId
                )
                await self?.removeBackgroundUploadTask(id: uploadId)
            }
            backgroundUploadTasks[uploadId] = task
        }
    }

    public func waitForBackgroundUploads() async {
        while !backgroundUploadTasks.isEmpty {
            let current = Array(backgroundUploadTasks.values)
            for task in current {
                await task.value
            }
        }
    }

    private func removeBackgroundUploadTask(id: String) {
        backgroundUploadTasks.removeValue(forKey: id)
    }

    private func finalizeCommittedScratch(
        itemId: UInt64,
        expectedGeneration: UInt64?,
        uploadId: String
    ) async {
        guard var scratch = scratchesById[itemId],
              let stack = stacksByAccountId[scratch.accountId],
              let uploadRecord = try? await stack.store.fetchUpload(id: uploadId),
              uploadRecord.state == .done else {
            return
        }

        var resolvedCommitted: DriveItem? = nil
        if let resultId = uploadRecord.resultDriveId {
            resolvedCommitted = try? await stack.store.fetchItem(driveId: resultId)
        }
        if resolvedCommitted == nil {
            resolvedCommitted = try? await stack.store.lookupChild(parentId: scratch.parentDriveId, name: uploadRecord.name)
        }
        if resolvedCommitted == nil {
            resolvedCommitted = try? await stack.store.lookupChild(parentId: scratch.parentDriveId, name: scratch.name)
        }

        guard var committed = resolvedCommitted else { return }

        if let perm = scratch.posixMode {
            committed.posixMode = perm
            try? await stack.store.updatePosixMode(driveId: committed.driveId, mode: perm)
            let client = stack.client
            let driveId = committed.driveId
            Task {
                try? await client.updatePosixMode(driveId: driveId, mode: perm)
            }
        }

        if expectedGeneration == nil || scratch.generation == expectedGeneration {
            if let cache = stack.cache {
                let chunkSize = await stack.reader.configuredChunkSize
                try? await cache.seedChunks(
                    from: scratch.localURL,
                    driveId: committed.driveId,
                    contentVersion: committed.contentVersionToken,
                    chunkSize: chunkSize,
                    pinned: committed.pinned
                )
            }
            scratchesById.removeValue(forKey: itemId)
            inodeByDriveKey.removeValue(forKey: "scratch:\(scratch.accountId):\(scratch.tempId)")
            try? FileManager.default.removeItem(at: scratch.localURL)

            let parentInode = nodesById[itemId]?.parentItemId ?? Self.rootItemId
            let updated = VFSNode(
                itemId: itemId,
                parentItemId: parentInode,
                kind: .remote(accountId: scratch.accountId, driveId: committed.driveId),
                name: committed.shownAs,
                isDirectory: committed.isFolder,
                size: committed.size,
                modifiedTime: committed.modifiedTime,
                posixMode: committed.posixMode,
                symlinkTarget: committed.symlinkTarget
            )
            nodesById[itemId] = updated
            inodeByDriveKey["remote:\(scratch.accountId):\(committed.driveId)"] = itemId
            bridgeSyncEpoch += 1
            DarwinNotifier.shared.post(.changed)
        } else {
            scratch.targetDriveId = committed.driveId
            scratch.baseVersion = committed.version
            scratch.baseHash = committed.md5
            scratchesById[itemId] = scratch
        }
    }

    private func reconcileCompletedScratches(for stack: MountedCloudStack) async {
        let candidates = scratchesById.compactMap { itemId, scratch -> (UInt64, UInt64, String)? in
            guard scratch.accountId == stack.account.id,
                  !scratch.dirty,
                  let uploadId = scratch.activeUploadId else {
                return nil
            }
            return (itemId, scratch.generation, uploadId)
        }
        for (itemId, gen, uploadId) in candidates {
            await finalizeCommittedScratch(itemId: itemId, expectedGeneration: gen, uploadId: uploadId)
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

        if case .scratch(let accountId, _) = node.kind,
           let activeId = scratchesById[itemId]?.activeUploadId,
           let bgTask = backgroundUploadTasks[activeId] {
            guard accountId == destAccountId else { throw POSIXError(.EXDEV) }
            await bgTask.value
            if let refreshed = nodesById[itemId] {
                node = refreshed
            }
        }

        switch node.kind {
        case .remote(let accountId, let driveId):
            guard accountId == destAccountId else { throw POSIXError(.EXDEV) }
            if stack.account.encryptionEnabled && stack.masterKey == nil {
                throw POSIXError(.EACCES)
            }
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
            updatedItem.posixMode = updatedItem.posixMode ?? node.posixMode
            updatedItem.symlinkTarget = updatedItem.symlinkTarget ?? node.symlinkTarget
            try await stack.store.upsertItem(updatedItem)
            node.name = updatedItem.shownAs
            node.parentItemId = destParentItemId
            nodesById[itemId] = node
            return node

        case .scratch(let accountId, _):
            guard accountId == destAccountId else { throw POSIXError(.EXDEV) }
            if var scratch = scratchesById[itemId] {
                if let activeId = scratch.activeUploadId {
                    try? await stack.store.deleteUpload(id: activeId)
                    scratch.activeUploadId = nil
                }
                scratch.name = newName
                scratch.parentDriveId = destParentDriveId
                scratch.dirty = true
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
            inodeByDriveKey.removeValue(forKey: "remote:\(accountId):\(driveId)")
            nodesById.removeValue(forKey: itemId)

        case .scratch(let accountId, let tempId):
            if let scratch = scratchesById.removeValue(forKey: itemId) {
                if let activeId = scratch.activeUploadId,
                   let stack = stacksByAccountId[accountId] {
                    try? await stack.store.requestCancelUpload(id: activeId)
                }
                inodeByDriveKey.removeValue(forKey: "scratch:\(accountId):\(tempId)")
                try? FileManager.default.removeItem(at: scratch.localURL)
            }
            nodesById.removeValue(forKey: itemId)

        default:
            throw POSIXError(.EPERM)
        }
    }

    // MARK: - File Provider Stable-ID Bridge API

    public func currentBridgeSyncAnchor() -> String {
        String(bridgeSyncEpoch)
    }

    public func bumpBridgeSyncEpoch() {
        bridgeSyncEpoch += 1
    }

    public func bridgeItem(forStableId stableId: String) async throws -> BridgeItem {
        if stableId == "root" {
            let root = rootNode()
            return BridgeItem(
                id: "root",
                parentId: "root",
                name: root.name,
                isFolder: true,
                size: 0,
                modifiedTime: root.modifiedTime,
                versionToken: "root",
                quotaLabel: finderQuotaLabel()
            )
        }

        if stableId.hasPrefix("acc:") {
            let accountId = String(stableId.dropFirst(4))
            guard let stack = stacksByAccountId[accountId] else {
                throw POSIXError(.ENOENT)
            }
            return BridgeItem(
                id: "acc:\(accountId)",
                parentId: "root",
                name: stack.account.displayName,
                isFolder: true,
                size: 0,
                modifiedTime: stack.account.rootCreatedAt ?? Date().timeIntervalSince1970,
                versionToken: stack.account.rootId ?? "root",
                quotaLabel: finderQuotaLabel(forAccountId: accountId)
            )
        }

        let (accountId, driveId) = try parseRemoteStableId(stableId)
        guard let stack = stacksByAccountId[accountId] else {
            throw POSIXError(.ENOENT)
        }

        let fetchedItem: DriveItem?
        if let cached = try await stack.store.fetchItem(driveId: driveId) {
            fetchedItem = cached
        } else if let remote = try await stack.client.fetchItemMetadata(driveId: driveId),
                  remote.trashedAt == nil,
                  !remote.isGoogleWorkspaceVirtualDocument {
            let decryptedRemote = VaultCrypto.decryptRemoteMetadata(remote, masterKey: stack.masterKey)
            try? await stack.store.upsertItem(decryptedRemote)
            fetchedItem = try await stack.store.fetchItem(driveId: driveId) ?? decryptedRemote
        } else {
            fetchedItem = nil
        }

        guard let item = fetchedItem else {
            throw POSIXError(.ENOENT)
        }
        return makeBridgeItem(from: item, stack: stack)
    }

    public func listBridgeChildren(parentStableId: String) async throws -> [BridgeItem] {
        if parentStableId == "root" {
            if let stack = singleFlattenedStack {
                let rootDriveId = stack.account.rootId ?? "root"
                let children = try await hydrateOrListChildren(parentDriveId: rootDriveId, stack: stack)
                return children.map { item in
                    let copy = makeBridgeItem(from: item, stack: stack)
                    return BridgeItem(
                        id: copy.id,
                        parentId: "root",
                        name: copy.name,
                        isFolder: copy.isFolder,
                        size: copy.size,
                        modifiedTime: copy.modifiedTime,
                        versionToken: copy.versionToken,
                        quotaLabel: copy.quotaLabel
                    )
                }
            }
            return stacksByAccountId.values
                .sorted { $0.account.displayName.localizedStandardCompare($1.account.displayName) == .orderedAscending }
                .map { stack in
                    BridgeItem(
                        id: "acc:\(stack.account.id)",
                        parentId: "root",
                        name: stack.account.displayName,
                        isFolder: true,
                        size: 0,
                        modifiedTime: stack.account.rootCreatedAt ?? Date().timeIntervalSince1970,
                        versionToken: stack.account.rootId ?? "root",
                        quotaLabel: finderQuotaLabel(forAccountId: stack.account.id)
                    )
                }
        }

        if parentStableId.hasPrefix("acc:") {
            let accountId = String(parentStableId.dropFirst(4))
            guard let stack = stacksByAccountId[accountId] else {
                throw POSIXError(.ENOENT)
            }
            let rootDriveId = stack.account.rootId ?? "root"
            let children = try await hydrateOrListChildren(parentDriveId: rootDriveId, stack: stack)
            let quotaLabel = finderQuotaLabel(forAccountId: accountId)
            return children.map { item in
                BridgeItem(
                    id: "item:\(accountId):\(item.driveId)",
                    parentId: parentStableId,
                    name: item.shownAs,
                    isFolder: item.isFolder,
                    size: item.size,
                    modifiedTime: item.modifiedTime,
                    versionToken: item.contentVersionToken,
                    quotaLabel: item.isFolder ? quotaLabel : nil
                )
            }
        }

        let (accountId, driveId) = try parseRemoteStableId(parentStableId)
        guard let stack = stacksByAccountId[accountId] else {
            throw POSIXError(.ENOENT)
        }
        let children = try await hydrateOrListChildren(parentDriveId: driveId, stack: stack)
        let quotaLabel = finderQuotaLabel(forAccountId: accountId)
        return children.map { item in
            BridgeItem(
                id: "item:\(accountId):\(item.driveId)",
                parentId: parentStableId,
                name: item.shownAs,
                isFolder: item.isFolder,
                size: item.size,
                modifiedTime: item.modifiedTime,
                versionToken: item.contentVersionToken,
                quotaLabel: item.isFolder ? quotaLabel : nil
            )
        }
    }

    public func readBridgeSlice(stableId: String, offset: Int64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        let (accountId, driveId) = try parseRemoteStableId(stableId)
        guard let stack = stacksByAccountId[accountId],
              let item = try await stack.store.fetchItem(driveId: driveId) else {
            throw POSIXError(.ENOENT)
        }
        guard !item.isFolder else {
            throw POSIXError(.EISDIR)
        }
        if offset == 0 {
            try? await stack.store.markOpened(driveId: driveId)
        }
        return try await stack.reader.readRange(
            item: item,
            offset: offset,
            length: length,
            masterKey: stack.masterKey
        )
    }

    public func createBridgeItem(
        parentStableId: String,
        name: String,
        isFolder: Bool,
        content: Data
    ) async throws -> BridgeItem {
        let parentInode = try await ensureInode(forStableId: parentStableId)
        let created = try await createItem(name: name, isDirectory: isFolder, inDirectory: parentInode)
        if !isFolder {
            if !content.isEmpty {
                _ = try await write(itemId: created.itemId, offset: 0, data: content)
            }
            try await closeAndCommitIfDirty(itemId: created.itemId)
        }
        bridgeSyncEpoch += 1
        DarwinNotifier.shared.post(.changed)

        if let updated = nodesById[created.itemId],
           case .remote(let accountId, let driveId) = updated.kind {
            return try await bridgeItem(forStableId: "item:\(accountId):\(driveId)")
        }

        // Offline/queued upload fallback while still in scratch state
        return BridgeItem(
            id: "scratch:\(created.itemId)",
            parentId: parentStableId,
            name: created.name,
            isFolder: isFolder,
            size: Int64(content.count),
            modifiedTime: Date().timeIntervalSince1970,
            versionToken: "\(content.count)"
        )
    }

    public func modifyBridgeItem(
        stableId: String,
        newParentStableId: String?,
        newName: String?,
        newContent: Data?
    ) async throws -> BridgeItem {
        let itemInode = try await ensureInode(forStableId: stableId)
        let current = try await bridgeItem(forStableId: stableId)

        let targetParentId = newParentStableId ?? current.parentId
        let targetName = newName ?? current.name
        if targetParentId != current.parentId || targetName != current.name {
            let destParentInode = try await ensureInode(forStableId: targetParentId)
            _ = try await renameItem(
                itemId: itemInode,
                toNewName: targetName,
                inDestinationDirectory: destParentInode
            )
        }

        if let newContent {
            _ = try await setAttributes(itemId: itemInode, newSize: 0, modifiedTime: Date().timeIntervalSince1970)
            if !newContent.isEmpty {
                _ = try await write(itemId: itemInode, offset: 0, data: newContent)
            }
            try await closeAndCommitIfDirty(itemId: itemInode)
        }

        bridgeSyncEpoch += 1
        DarwinNotifier.shared.post(.changed)
        return try await bridgeItem(forStableId: stableId)
    }

    public func deleteBridgeItem(stableId: String) async throws {
        let itemInode = try await ensureInode(forStableId: stableId)
        try await removeItem(itemId: itemInode)
        bridgeSyncEpoch += 1
        DarwinNotifier.shared.post(.changed)
    }

    private func hydrateOrListChildren(parentDriveId: String, stack: MountedCloudStack) async throws -> [DriveItem] {
        if let hydrated = try? await stack.syncer.hydrateFolderIfNeeded(
            folderId: parentDriveId,
            masterKey: stack.masterKey
        ) {
            return hydrated
        }
        return try await stack.store.listChildren(parentId: parentDriveId)
    }

    private func parseRemoteStableId(_ stableId: String) throws -> (accountId: String, driveId: String) {
        guard stableId.hasPrefix("item:") else {
            throw POSIXError(.ENOENT)
        }
        let remainder = stableId.dropFirst(5)
        guard let sep = remainder.firstIndex(of: ":") else {
            throw POSIXError(.ENOENT)
        }
        let accountId = String(remainder[..<sep])
        let driveId = String(remainder[remainder.index(after: sep)...])
        guard !accountId.isEmpty, !driveId.isEmpty else {
            throw POSIXError(.ENOENT)
        }
        return (accountId, driveId)
    }

    private func ensureInode(forStableId stableId: String) async throws -> UInt64 {
        if stableId == "root" {
            return Self.rootItemId
        }
        if stableId.hasPrefix("acc:") {
            let accountId = String(stableId.dropFirst(4))
            guard let inode = inodeByDriveKey["cloudRoot:\(accountId)"] else {
                throw POSIXError(.ENOENT)
            }
            return inode
        }

        let (accountId, driveId) = try parseRemoteStableId(stableId)
        let key = "remote:\(accountId):\(driveId)"
        if let existing = inodeByDriveKey[key], nodesById[existing] != nil {
            return existing
        }
        guard let stack = stacksByAccountId[accountId] else {
            throw POSIXError(.ENOENT)
        }
        let fetched: DriveItem?
        if let stored = try await stack.store.fetchItem(driveId: driveId) {
            fetched = stored
        } else if let remote = try await stack.client.fetchItemMetadata(driveId: driveId) {
            let decryptedRemote = VaultCrypto.decryptRemoteMetadata(remote, masterKey: stack.masterKey)
            try? await stack.store.upsertItem(decryptedRemote)
            fetched = try await stack.store.fetchItem(driveId: driveId) ?? decryptedRemote
        } else {
            fetched = nil
        }
        guard let item = fetched else {
            throw POSIXError(.ENOENT)
        }
        let parentInode: UInt64
        if let pid = item.parentId,
           pid != stack.account.rootId,
           !(stack.account.wholeDrive && pid == "root"),
           let pInode = inodeByDriveKey["remote:\(accountId):\(pid)"] {
            parentInode = pInode
        } else if singleFlattenedStack?.account.id == accountId {
            parentInode = Self.rootItemId
        } else if let accInode = inodeByDriveKey["cloudRoot:\(accountId)"] {
            parentInode = accInode
        } else {
            parentInode = Self.rootItemId
        }
        return registerDriveItemNode(item, accountId: accountId, parentInode: parentInode).itemId
    }

    private func makeBridgeItem(from item: DriveItem, stack: MountedCloudStack) -> BridgeItem {
        let rootDriveId = stack.account.rootId ?? "root"
        let parentStableId: String
        if item.parentId == nil || item.parentId == rootDriveId || (stack.account.wholeDrive && item.parentId == "root") {
            parentStableId = (singleFlattenedStack?.account.id == stack.account.id)
                ? "root"
                : "acc:\(stack.account.id)"
        } else {
            parentStableId = "item:\(stack.account.id):\(item.parentId!)"
        }
        return BridgeItem(
            id: "item:\(stack.account.id):\(item.driveId)",
            parentId: parentStableId,
            name: item.shownAs,
            isFolder: item.isFolder,
            size: item.size,
            modifiedTime: item.modifiedTime,
            versionToken: item.contentVersionToken,
            quotaLabel: item.isFolder ? finderQuotaLabel(forAccountId: stack.account.id) : nil
        )
    }

    // MARK: - Private Helpers

    private func listRemoteParent(
        accountId: String,
        parentDriveId: String,
        parentInode: UInt64
    ) async throws -> [VFSNode] {
        guard let stack = stacksByAccountId[accountId] else { return [] }
        let dbChildren: [DriveItem]
        if let hydrated = try? await stack.syncer.hydrateFolderIfNeeded(
            folderId: parentDriveId,
            masterKey: stack.masterKey
        ) {
            dbChildren = hydrated
        } else {
            dbChildren = try await stack.store.listChildren(parentId: parentDriveId)
        }
        var result: [VFSNode] = dbChildren.map { item in
            registerDriveItemNode(item, accountId: accountId, parentInode: parentInode)
        }
        let emittedInodes = Set(result.map(\.itemId))
        let emittedNames = Set(dbChildren.map { MetadataStore.fold($0.shownAs) })

        // Include any uncommitted scratch files in this directory
        for (inode, scratch) in scratchesById
        where scratch.accountId == accountId
            && scratch.parentDriveId == parentDriveId
            && scratch.targetDriveId == nil
            && !emittedInodes.contains(inode)
            && !emittedNames.contains(MetadataStore.fold(scratch.name)) {
            if let scratchNode = nodesById[inode] {
                result.append(scratchNode)
            }
        }
        return result
    }

    private func registerDriveItemNode(_ item: DriveItem, accountId: String, parentInode: UInt64) -> VFSNode {
        let key = "remote:\(accountId):\(item.driveId)"
        let inode = inodeByDriveKey[key] ?? allocateInode(forKey: key)
        let activeScratch = scratchesById[inode]
        let size = activeScratch?.size ?? item.size
        let posixMode = activeScratch?.posixMode ?? item.posixMode
        let node = VFSNode(
            itemId: inode,
            parentItemId: parentInode,
            kind: .remote(accountId: accountId, driveId: item.driveId),
            name: item.shownAs,
            isDirectory: item.isFolder,
            size: size,
            modifiedTime: item.modifiedTime,
            posixMode: posixMode,
            symlinkTarget: item.symlinkTarget
        )
        nodesById[inode] = node
        return node
    }

    private func resolveParentDriveContext(for dirNode: VFSNode) throws -> (accountId: String, driveId: String) {
        switch dirNode.kind {
        case .root:
            guard let stack = singleFlattenedStack else { throw POSIXError(.EPERM) }
            return (stack.account.id, stack.account.rootId ?? "root")
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

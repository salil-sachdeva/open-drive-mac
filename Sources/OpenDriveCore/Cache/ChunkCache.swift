import Foundation

/// On-disk LRU chunk cache (`~/Library/Caches/OpenDrive/chunks`).
public actor ChunkCache {
    public struct Entry: Codable, Sendable {
        public let key: String
        public let fileName: String
        public let size: Int64
        public var lastAccessedAt: Double
        public var pinned: Bool
    }

    private struct DiskRecord: Codable, Sendable {
        let key: String
        let driveId: String
        let fileName: String
        var size: Int64
        var lastAccessedAt: Double
        var pinned: Bool
        var hitCount: Int

        enum CodingKeys: String, CodingKey {
            case key
            case driveId
            case fileName
            case size
            case lastAccessedAt
            case pinned
            case hitCount
        }

        init(
            key: String,
            driveId: String,
            fileName: String,
            size: Int64,
            lastAccessedAt: Double,
            pinned: Bool,
            hitCount: Int = 1
        ) {
            self.key = key
            self.driveId = driveId
            self.fileName = fileName
            self.size = size
            self.lastAccessedAt = lastAccessedAt
            self.pinned = pinned
            self.hitCount = max(1, hitCount)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.key = try c.decode(String.self, forKey: .key)
            self.driveId = try c.decode(String.self, forKey: .driveId)
            self.fileName = try c.decode(String.self, forKey: .fileName)
            self.size = try c.decode(Int64.self, forKey: .size)
            self.lastAccessedAt = try c.decode(Double.self, forKey: .lastAccessedAt)
            self.pinned = try c.decode(Bool.self, forKey: .pinned)
            self.hitCount = max(1, try c.decodeIfPresent(Int.self, forKey: .hitCount) ?? 1)
        }
    }

    private static let manifestFileName = ".chunk-index.json"

    public let cacheDirectory: URL
    public private(set) var maxBytes: Int64
    public private(set) var totalBytes: Int64 = 0
    public private(set) var hotBytes: Int64 = 0
    private var entriesByFileName: [String: DiskRecord] = [:]

    public init(
        cacheDirectory: URL = OpenDrivePaths.chunksCacheURL,
        maxBytes: Int64 = 5 * 1024 * 1024 * 1024 // Default 5 GiB
    ) throws {
        self.cacheDirectory = cacheDirectory
        self.maxBytes = maxBytes
        try OpenDrivePaths.createPrivateDirectory(at: cacheDirectory)
        let initial = Self.loadAndReconcile(cacheDirectory: cacheDirectory, maxBytes: maxBytes)
        self.entriesByFileName = initial.entries
        self.totalBytes = initial.totalBytes
        self.hotBytes = initial.hotBytes
    }

    public func setMaxBytes(_ newLimit: Int64) {
        self.maxBytes = max(64 * 1024 * 1024, newLimit)
        let evicted = Self.evictIfNeeded(
            entriesByFileName: &entriesByFileName,
            totalBytes: &totalBytes,
            hotBytes: &hotBytes,
            maxBytes: maxBytes,
            cacheDirectory: cacheDirectory
        )
        if evicted {
            Self.persistManifest(entriesByFileName: entriesByFileName, cacheDirectory: cacheDirectory)
        }
    }

    public func contains(_ key: ChunkKey) -> Bool {
        let fileName = key.cacheFileName
        guard Self.isSafeCacheFileName(fileName), entriesByFileName[fileName] != nil else { return false }
        let fileURL = cacheDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    public func get(_ key: ChunkKey) -> Data? {
        let fileName = key.cacheFileName
        guard Self.isSafeCacheFileName(fileName) else { return nil }
        let fileURL = cacheDirectory.appendingPathComponent(fileName)

        guard var record = entriesByFileName[fileName] else {
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL) else {
                return nil
            }
            let now = Date().timeIntervalSince1970
            let recovered = DiskRecord(
                key: key.description,
                driveId: key.driveId,
                fileName: fileName,
                size: Int64(data.count),
                lastAccessedAt: now,
                pinned: false,
                hitCount: 1
            )
            entriesByFileName[fileName] = recovered
            totalBytes += recovered.size
            hotBytes = Self.computeHotBytes(entriesByFileName)
            Self.persistManifest(entriesByFileName: entriesByFileName, cacheDirectory: cacheDirectory)
            return data
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            entriesByFileName.removeValue(forKey: fileName)
            totalBytes = max(0, totalBytes - record.size)
            hotBytes = Self.computeHotBytes(entriesByFileName)
            Self.persistManifest(entriesByFileName: entriesByFileName, cacheDirectory: cacheDirectory)
            return nil
        }

        record.lastAccessedAt = Date().timeIntervalSince1970
        record.hitCount += 1
        entriesByFileName[fileName] = record
        hotBytes = Self.computeHotBytes(entriesByFileName)
        Self.persistManifest(entriesByFileName: entriesByFileName, cacheDirectory: cacheDirectory)
        return data
    }

    public func put(
        _ data: Data,
        for key: ChunkKey,
        pinned: Bool = false,
        initialHitCount: Int = 1
    ) throws {
        let fileName = key.cacheFileName
        guard Self.isSafeCacheFileName(fileName) else {
            throw POSIXError(.EINVAL)
        }
        let fileURL = cacheDirectory.appendingPathComponent(fileName)
        try OpenDrivePaths.writePrivateFile(data, to: fileURL)

        let previousHitCount = entriesByFileName[fileName]?.hitCount ?? 0
        if let existing = entriesByFileName[fileName] {
            totalBytes = max(0, totalBytes - existing.size)
        }

        let size = Int64(data.count)
        let record = DiskRecord(
            key: key.description,
            driveId: key.driveId,
            fileName: fileName,
            size: size,
            lastAccessedAt: Date().timeIntervalSince1970,
            pinned: pinned,
            hitCount: max(1, max(previousHitCount, initialHitCount))
        )
        entriesByFileName[fileName] = record
        totalBytes += size
        _ = Self.evictIfNeeded(
            entriesByFileName: &entriesByFileName,
            totalBytes: &totalBytes,
            hotBytes: &hotBytes,
            maxBytes: maxBytes,
            cacheDirectory: cacheDirectory
        )
        hotBytes = Self.computeHotBytes(entriesByFileName)
        Self.persistManifest(entriesByFileName: entriesByFileName, cacheDirectory: cacheDirectory)
    }

    /// Streams a newly uploaded local file into hot chunks (`hitCount >= 2`) so reopening it
    /// immediately requires zero remote downloads while capping per-file seeding to `maxBytes / 2`.
    public func seedChunks(
        from localFileURL: URL,
        driveId: String,
        contentVersion: String,
        chunkSize: Int = OpenDrivePaths.defaultChunkSize,
        pinned: Bool = false
    ) throws {
        guard chunkSize > 0, FileManager.default.fileExists(atPath: localFileURL.path) else {
            return
        }
        let handle = try FileHandle(forReadingFrom: localFileURL)
        defer { try? handle.close() }

        let seedCap = maxBytes / 2
        var seededBytes: Int64 = 0
        var chunkIndex = 0

        while true {
            let chunkData = try handle.read(upToCount: chunkSize) ?? Data()
            if chunkData.isEmpty {
                break
            }
            if seededBytes + Int64(chunkData.count) > seedCap {
                break
            }
            let key = ChunkKey(driveId: driveId, contentVersion: contentVersion, index: chunkIndex)
            try put(chunkData, for: key, pinned: pinned, initialHitCount: 2)
            seededBytes += Int64(chunkData.count)
            chunkIndex += 1
        }
    }

    public func invalidate(driveId: String) {
        let safeDriveId = ChunkKey.sanitizeSegment(driveId)
        let matchingFileNames = entriesByFileName.compactMap { fileName, record -> String? in
            if record.driveId == driveId || fileName.hasPrefix("\(safeDriveId)_") {
                return fileName
            }
            return nil
        }
        guard !matchingFileNames.isEmpty else { return }

        for fileName in matchingFileNames {
            if let removed = entriesByFileName.removeValue(forKey: fileName) {
                totalBytes = max(0, totalBytes - removed.size)
                if Self.isSafeCacheFileName(removed.fileName) {
                    let fileURL = cacheDirectory.appendingPathComponent(removed.fileName)
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }
        hotBytes = Self.computeHotBytes(entriesByFileName)
        Self.persistManifest(entriesByFileName: entriesByFileName, cacheDirectory: cacheDirectory)
    }

    public func clearAll() {
        entriesByFileName.removeAll()
        totalBytes = 0
        hotBytes = 0
        if let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            for url in files {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Disk Manifest & Eviction

    private static func loadAndReconcile(
        cacheDirectory: URL,
        maxBytes: Int64
    ) -> (entries: [String: DiskRecord], totalBytes: Int64, hotBytes: Int64) {
        let manifestURL = cacheDirectory.appendingPathComponent(manifestFileName)
        var savedByFileName: [String: DiskRecord] = [:]
        if let data = try? Data(contentsOf: manifestURL),
           let decoded = try? JSONDecoder().decode([DiskRecord].self, from: data) {
            for item in decoded where isSafeCacheFileName(item.fileName) {
                savedByFileName[item.fileName] = item
            }
        }

        var reconciled: [String: DiskRecord] = [:]
        var runningTotal: Int64 = 0

        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        if let diskURLs = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: Array(resourceKeys)
        ) {
            for url in diskURLs where url.pathExtension == "chunk" {
                let fileName = url.lastPathComponent
                let values = try? url.resourceValues(forKeys: resourceKeys)
                guard values?.isRegularFile ?? true else { continue }
                let diskSize = Int64(values?.fileSize ?? 0)
                let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970

                if var existing = savedByFileName[fileName] {
                    existing.size = diskSize
                    reconciled[fileName] = existing
                } else {
                    let stem = url.deletingPathExtension().lastPathComponent
                    let guessedDriveId = stem.split(separator: "_", maxSplits: 1).first.map(String.init) ?? stem
                    reconciled[fileName] = DiskRecord(
                        key: stem,
                        driveId: guessedDriveId,
                        fileName: fileName,
                        size: diskSize,
                        lastAccessedAt: mtime,
                        pinned: false,
                        hitCount: 1
                    )
                }
                runningTotal += diskSize
            }
        }

        var runningHot = computeHotBytes(reconciled)
        _ = evictIfNeeded(
            entriesByFileName: &reconciled,
            totalBytes: &runningTotal,
            hotBytes: &runningHot,
            maxBytes: maxBytes,
            cacheDirectory: cacheDirectory
        )
        persistManifest(entriesByFileName: reconciled, cacheDirectory: cacheDirectory)
        return (reconciled, runningTotal, runningHot)
    }

    @discardableResult
    private static func evictIfNeeded(
        entriesByFileName: inout [String: DiskRecord],
        totalBytes: inout Int64,
        hotBytes: inout Int64,
        maxBytes: Int64,
        cacheDirectory: URL
    ) -> Bool {
        guard totalBytes > maxBytes else {
            hotBytes = computeHotBytes(entriesByFileName)
            return false
        }

        // First evict one-off cold previews (hitCount <= 1) before touching repeated hot chunks.
        let coldEntries = entriesByFileName
            .filter { !$0.value.pinned && $0.value.hitCount <= 1 }
            .sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }

        var evictedAny = false
        for (fileName, record) in coldEntries {
            guard totalBytes > maxBytes else { break }
            entriesByFileName.removeValue(forKey: fileName)
            totalBytes = max(0, totalBytes - record.size)
            if isSafeCacheFileName(record.fileName) {
                let fileURL = cacheDirectory.appendingPathComponent(record.fileName)
                try? FileManager.default.removeItem(at: fileURL)
            }
            evictedAny = true
        }

        if totalBytes > maxBytes {
            let hotUnpinned = entriesByFileName
                .filter { !$0.value.pinned && $0.value.hitCount >= 2 }
                .sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }
            for (fileName, record) in hotUnpinned {
                guard totalBytes > maxBytes else { break }
                entriesByFileName.removeValue(forKey: fileName)
                totalBytes = max(0, totalBytes - record.size)
                if isSafeCacheFileName(record.fileName) {
                    let fileURL = cacheDirectory.appendingPathComponent(record.fileName)
                    try? FileManager.default.removeItem(at: fileURL)
                }
                evictedAny = true
            }
        }

        hotBytes = computeHotBytes(entriesByFileName)
        return evictedAny
    }

    private static func isSafeCacheFileName(_ name: String) -> Bool {
        !name.isEmpty
            && !name.hasPrefix(".")
            && !name.contains("/")
            && !name.contains("\\")
            && !name.contains("..")
            && !name.contains("\0")
    }

    private static func computeHotBytes(_ entriesByFileName: [String: DiskRecord]) -> Int64 {
        entriesByFileName.values.reduce(0) { sum, record in
            (record.pinned || record.hitCount >= 2) ? (sum + record.size) : sum
        }
    }

    private static func persistManifest(entriesByFileName: [String: DiskRecord], cacheDirectory: URL) {
        let manifestURL = cacheDirectory.appendingPathComponent(manifestFileName)
        let records = Array(entriesByFileName.values)
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? OpenDrivePaths.writePrivateFile(data, to: manifestURL)
    }
}

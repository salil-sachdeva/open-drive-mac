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

    public let cacheDirectory: URL
    public private(set) var maxBytes: Int64
    public private(set) var totalBytes: Int64 = 0
    private var entries: [ChunkKey: Entry] = [:]

    public init(
        cacheDirectory: URL = OpenDrivePaths.chunksCacheURL,
        maxBytes: Int64 = 5 * 1024 * 1024 * 1024 // Default 5 GiB
    ) throws {
        self.cacheDirectory = cacheDirectory
        self.maxBytes = maxBytes
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    public func setMaxBytes(_ newLimit: Int64) {
        self.maxBytes = max(64 * 1024 * 1024, newLimit)
        evictIfNeeded()
    }

    public func get(_ key: ChunkKey) -> Data? {
        guard var entry = entries[key] else {
            let fileURL = cacheDirectory.appendingPathComponent(key.cacheFileName)
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL) else {
                return nil
            }
            let now = Date().timeIntervalSince1970
            let recovered = Entry(
                key: key.description,
                fileName: key.cacheFileName,
                size: Int64(data.count),
                lastAccessedAt: now,
                pinned: false
            )
            entries[key] = recovered
            totalBytes += recovered.size
            return data
        }

        let fileURL = cacheDirectory.appendingPathComponent(entry.fileName)
        guard let data = try? Data(contentsOf: fileURL) else {
            entries.removeValue(forKey: key)
            totalBytes = max(0, totalBytes - entry.size)
            return nil
        }
        entry.lastAccessedAt = Date().timeIntervalSince1970
        entries[key] = entry
        return data
    }

    public func put(_ data: Data, for key: ChunkKey, pinned: Bool = false) throws {
        let fileURL = cacheDirectory.appendingPathComponent(key.cacheFileName)
        try data.write(to: fileURL, options: .atomic)

        if let existing = entries[key] {
            totalBytes = max(0, totalBytes - existing.size)
        }
        let size = Int64(data.count)
        let entry = Entry(
            key: key.description,
            fileName: key.cacheFileName,
            size: size,
            lastAccessedAt: Date().timeIntervalSince1970,
            pinned: pinned
        )
        entries[key] = entry
        totalBytes += size
        evictIfNeeded()
    }

    public func invalidate(driveId: String) {
        let matchingKeys = entries.keys.filter { $0.driveId == driveId }
        for key in matchingKeys {
            if let removed = entries.removeValue(forKey: key) {
                totalBytes = max(0, totalBytes - removed.size)
                let fileURL = cacheDirectory.appendingPathComponent(removed.fileName)
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    public func clearAll() {
        entries.removeAll()
        totalBytes = 0
        if let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            for url in files {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func evictIfNeeded() {
        guard totalBytes > maxBytes else { return }
        let unpinned = entries
            .filter { !$0.value.pinned }
            .sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }

        for (key, entry) in unpinned {
            guard totalBytes > maxBytes else { break }
            entries.removeValue(forKey: key)
            totalBytes = max(0, totalBytes - entry.size)
            let fileURL = cacheDirectory.appendingPathComponent(entry.fileName)
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}

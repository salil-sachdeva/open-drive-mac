import Foundation
import CryptoKit

// MARK: - RangePlanner

public struct ChunkSlicePlan: Sendable, Equatable {
    public let chunkIndex: Int
    public let sliceOffsetInChunk: Int
    public let sliceLength: Int

    public init(chunkIndex: Int, sliceOffsetInChunk: Int, sliceLength: Int) {
        self.chunkIndex = chunkIndex
        self.sliceOffsetInChunk = sliceOffsetInChunk
        self.sliceLength = sliceLength
    }
}

public enum RangePlanner {
    /// Maps an arbitrary POSIX `(offset, length)` read into fixed-size chunk slices, clamped to `fileSize`.
    public static func plan(
        offset: Int64,
        length: Int,
        fileSize: Int64,
        chunkSize: Int = OpenDrivePaths.defaultChunkSize
    ) -> [ChunkSlicePlan] {
        guard offset >= 0, length > 0, offset < fileSize, chunkSize > 0 else {
            return []
        }
        let clampedEnd = min(fileSize, offset + Int64(length))
        var plans: [ChunkSlicePlan] = []
        var cursor = offset

        while cursor < clampedEnd {
            let chunkIndex = Int(cursor / Int64(chunkSize))
            let chunkStart = Int64(chunkIndex) * Int64(chunkSize)
            let sliceOffset = Int(cursor - chunkStart)
            let maxInThisChunk = min(clampedEnd, chunkStart + Int64(chunkSize)) - cursor
            let sliceLen = Int(maxInThisChunk)
            plans.append(
                ChunkSlicePlan(
                    chunkIndex: chunkIndex,
                    sliceOffsetInChunk: sliceOffset,
                    sliceLength: sliceLen
                )
            )
            cursor += maxInThisChunk
        }
        return plans
    }
}

// MARK: - SequentialReadDetector

/// Tracks sequential chunk access per `driveId` and returns lookahead chunk indices once a streak is established.
public struct SequentialReadDetector: Sendable {
    private var lastChunkByDriveId: [String: Int] = [:]
    private var streakByDriveId: [String: Int] = [:]
    public let streakThreshold: Int
    public let lookaheadCount: Int

    public init(streakThreshold: Int = 2, lookaheadCount: Int = 2) {
        self.streakThreshold = streakThreshold
        self.lookaheadCount = lookaheadCount
    }

    public mutating func recordRead(
        driveId: String,
        chunkIndex: Int,
        totalChunks: Int
    ) -> [Int] {
        if let last = lastChunkByDriveId[driveId] {
            if chunkIndex == last {
                // Repeat read inside the same chunk; keep current streak
            } else if chunkIndex == last + 1 {
                streakByDriveId[driveId, default: 1] += 1
                lastChunkByDriveId[driveId] = chunkIndex
            } else {
                streakByDriveId[driveId] = 1
                lastChunkByDriveId[driveId] = chunkIndex
            }
        } else {
            lastChunkByDriveId[driveId] = chunkIndex
            streakByDriveId[driveId] = 1
        }

        let currentStreak = streakByDriveId[driveId, default: 0]
        guard currentStreak >= streakThreshold else { return [] }

        var prefetchIndices: [Int] = []
        for delta in 1...lookaheadCount {
            let candidate = chunkIndex + delta
            if candidate < totalChunks {
                prefetchIndices.append(candidate)
            }
        }
        return prefetchIndices
    }
}

// MARK: - RangeReader Actor

/// Coalesces in-flight chunk downloads (`inFlight: [ChunkKey: Task<Data, Error>]`), transparently decrypts `ODE1`
/// chunks when `item.isEncrypted == true`, caches plaintext chunks on disk in `ChunkCache`, and prefetches sequential reads.
public actor RangeReader {
    public typealias ByteRangeFetcher = @Sendable (_ driveId: String, _ offset: Int64, _ length: Int) async throws -> Data

    private let cache: ChunkCache
    private let chunkSize: Int
    private let fetcher: ByteRangeFetcher
    private var inFlight: [ChunkKey: Task<Data, Error>] = [:]
    private var headerCache: [String: (header: VaultCrypto.ODE1Header, fileKey: SymmetricKey)] = [:]
    private var detector = SequentialReadDetector()

    public var configuredChunkSize: Int {
        chunkSize
    }

    public init(
        cache: ChunkCache,
        chunkSize: Int = OpenDrivePaths.defaultChunkSize,
        fetcher: @escaping ByteRangeFetcher
    ) {
        self.cache = cache
        self.chunkSize = chunkSize
        self.fetcher = fetcher
    }

    public func isChunkCached(item: DriveItem, chunkIndex: Int) async -> Bool {
        let key = ChunkKey(
            driveId: item.driveId,
            contentVersion: item.contentVersionToken,
            index: chunkIndex
        )
        return await cache.contains(key)
    }

    public func readRange(
        item: DriveItem,
        offset: Int64,
        length: Int,
        masterKey: SymmetricKey? = nil
    ) async throws -> Data {
        let plans = RangePlanner.plan(
            offset: offset,
            length: length,
            fileSize: item.size,
            chunkSize: chunkSize
        )
        guard !plans.isEmpty else { return Data() }

        let totalChunks = max(1, Int((item.size + Int64(chunkSize) - 1) / Int64(chunkSize)))
        let plannedBytes = plans.reduce(0) { $0 + $1.sliceLength }
        var output = Data(capacity: plannedBytes)

        for plan in plans {
            let key = ChunkKey(
                driveId: item.driveId,
                contentVersion: item.contentVersionToken,
                index: plan.chunkIndex
            )
            let chunkData = try await fetchOrCoalesceChunk(
                key: key,
                item: item,
                masterKey: masterKey
            )
            let safeStart = min(plan.sliceOffsetInChunk, chunkData.count)
            let safeEnd = min(safeStart + plan.sliceLength, chunkData.count)
            if safeStart < safeEnd {
                output.append(chunkData.subdata(in: safeStart..<safeEnd))
            }

            // Trigger background prefetch if sequential streak detected
            let prefetchTargets = detector.recordRead(
                driveId: item.driveId,
                chunkIndex: plan.chunkIndex,
                totalChunks: totalChunks
            )
            for nextIdx in prefetchTargets {
                let nextKey = ChunkKey(
                    driveId: item.driveId,
                    contentVersion: item.contentVersionToken,
                    index: nextIdx
                )
                Task {
                    _ = try? await self.fetchOrCoalesceChunk(
                        key: nextKey,
                        item: item,
                        masterKey: masterKey
                    )
                }
            }
        }

        return output
    }

    private func fetchOrCoalesceChunk(
        key: ChunkKey,
        item: DriveItem,
        masterKey: SymmetricKey?
    ) async throws -> Data {
        if let cached = await cache.get(key) {
            return cached
        }
        if let existingTask = inFlight[key] {
            return try await existingTask.value
        }

        let task = Task<Data, Error> { [cache, chunkSize, fetcher] in
            if item.isEncrypted {
                guard let masterKey else {
                    throw VaultCryptoError.authenticationFailed
                }
                let (header, fileKey) = try await self.resolveODE1Header(
                    driveId: item.driveId,
                    version: item.contentVersionToken,
                    masterKey: masterKey
                )
                guard let encRange = VaultCrypto.encryptedChunkRange(
                    chunkIndex: key.index,
                    plaintextFileSize: item.size,
                    chunkSize: chunkSize
                ) else {
                    return Data()
                }
                let encryptedSlice = try await fetcher(item.driveId, encRange.offset, encRange.length)
                let decrypted = try VaultCrypto.decryptChunk(
                    encryptedSlice,
                    chunkIndex: key.index,
                    noncePrefix: header.noncePrefix,
                    fileKey: fileKey
                )
                try await cache.put(decrypted, for: key, pinned: item.pinned)
                return decrypted
            } else {
                let chunkStart = Int64(key.index) * Int64(chunkSize)
                let remaining = max(0, item.size - chunkStart)
                let fetchLen = Int(min(Int64(chunkSize), remaining))
                guard fetchLen > 0 else { return Data() }
                let data = try await fetcher(item.driveId, chunkStart, fetchLen)
                try await cache.put(data, for: key, pinned: item.pinned)
                return data
            }
        }

        inFlight[key] = task
        defer { inFlight.removeValue(forKey: key) }
        return try await task.value
    }

    private func resolveODE1Header(
        driveId: String,
        version: String,
        masterKey: SymmetricKey
    ) async throws -> (header: VaultCrypto.ODE1Header, fileKey: SymmetricKey) {
        let cacheKey = "\(driveId)@\(version)"
        if let cached = headerCache[cacheKey] {
            return cached
        }
        let headerBytes = try await fetcher(driveId, 0, VaultCrypto.headerSize)
        let header = try VaultCrypto.ODE1Header.parse(from: headerBytes)
        let fileKey = try VaultCrypto.unwrapFileKey(header: header, masterKey: masterKey)
        headerCache[cacheKey] = (header, fileKey)
        return (header, fileKey)
    }
}

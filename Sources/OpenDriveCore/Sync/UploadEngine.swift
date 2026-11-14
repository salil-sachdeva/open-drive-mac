import CryptoKit
import Foundation

/// Durable background upload actor supporting resumable chunked uploads (`256 KiB`-aligned chunks),
/// metered-network auto-pause, bandwidth throttling (`BandwidthMode`), optimistic concurrency
/// (`baseVersion` / `baseHash`) with automatic `ConflictName` generation, and `FDE1` encryption.
public actor UploadEngine {
    public static let uploadQuantumSize: Int = 4 * 1024 * 1024 // 4 MiB upload chunks

    private let store: MetadataStore
    private let client: any CloudDrive
    private var bandwidthMode: BandwidthMode = .off
    private var pauseOnMetered: Bool = true
    private var isNetworkMetered: Bool = false
    private var isNetworkOffline: Bool = false
    private var isRunning: Bool = false

    public init(store: MetadataStore, client: any CloudDrive) {
        self.store = store
        self.client = client
    }

    public func setBandwidthMode(_ mode: BandwidthMode) {
        self.bandwidthMode = mode
    }

    public func setPauseOnMetered(_ enabled: Bool) {
        self.pauseOnMetered = enabled
    }

    public func setNetworkMetered(_ metered: Bool) {
        self.isNetworkMetered = metered
    }

    public func setNetworkState(isMetered: Bool, isOffline: Bool) {
        self.isNetworkMetered = isMetered
        self.isNetworkOffline = isOffline
    }

    @discardableResult
    public func enqueueUpload(
        localURL: URL,
        parentId: String,
        targetDriveId: String?,
        name: String,
        mime: String = "application/octet-stream",
        baseVersion: String? = nil,
        baseHash: String? = nil,
        encrypt: Bool = false
    ) async throws -> UploadRecord {
        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        let record = UploadRecord(
            localPath: localURL.path,
            parentId: parentId,
            targetDriveId: targetDriveId,
            name: name,
            size: size,
            mime: mime,
            state: .queued,
            baseVersion: baseVersion,
            encrypt: encrypt,
            baseHash: baseHash
        )
        try await store.upsertUpload(record)
        DarwinNotifier.shared.post(.changed)
        return record
    }

    public func processQueue(masterKey: SymmetricKey? = nil) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        guard let pending = try? await store.fetchPendingUploads() else { return }
        for var record in pending {
            if record.cancelRequested {
                try? await store.deleteUpload(id: record.id)
                DarwinNotifier.shared.post(.changed)
                continue
            }
            if isNetworkOffline {
                record.state = .paused
                record.pausedReason = .offline
                try? await store.upsertUpload(record)
                DarwinNotifier.shared.post(.changed)
                continue
            }
            if pauseOnMetered && isNetworkMetered {
                record.state = .paused
                record.pausedReason = .metered
                try? await store.upsertUpload(record)
                DarwinNotifier.shared.post(.changed)
                continue
            }
            await processSingleUpload(&record, masterKey: masterKey)
        }
    }

    private func processSingleUpload(_ record: inout UploadRecord, masterKey: SymmetricKey?) async {
        do {
            let localURL = URL(fileURLWithPath: record.localPath)
            guard FileManager.default.fileExists(atPath: localURL.path) else {
                try await store.deleteUpload(id: record.id)
                return
            }

            if let targetId = record.targetDriveId,
               let remoteCurrent = try await client.fetchItemMetadata(driveId: targetId) {
                let versionChanged = (record.baseVersion != nil && remoteCurrent.version != nil && record.baseVersion != remoteCurrent.version)
                let hashChanged = (record.baseHash != nil && remoteCurrent.md5 != nil && record.baseHash != remoteCurrent.md5)
                if versionChanged || hashChanged {
                    record.name = ConflictName.make(for: record.name)
                    record.targetDriveId = nil
                    record.sessionURL = nil
                    record.offset = 0
                    record.renamedLate = true
                }
            }

            let payloadData: Data
            let remoteFilename: String
            let rawData = try Data(contentsOf: localURL)
            if record.encrypt {
                guard let masterKey else {
                    throw VaultCryptoError.authenticationFailed
                }
                payloadData = try VaultCrypto.encryptFileData(rawData, masterKey: masterKey)
                remoteFilename = try VaultCrypto.encryptFilename(record.name, masterKey: masterKey)
            } else {
                payloadData = rawData
                remoteFilename = record.name
            }

            let totalWireSize = Int64(payloadData.count)
            record.state = .uploading
            record.pausedReason = nil
            try await store.upsertUpload(record)

            let sessionURL: URL
            if let existingURLString = record.sessionURL, let url = URL(string: existingURLString) {
                sessionURL = url
            } else {
                let createdURL = try await client.startResumableUpload(
                    name: remoteFilename,
                    parentId: record.parentId,
                    targetDriveId: record.targetDriveId,
                    mime: record.mime,
                    totalSize: totalWireSize,
                    isEncrypted: record.encrypt
                )
                record.sessionURL = createdURL.absoluteString
                try await store.upsertUpload(record)
                sessionURL = createdURL
            }

            var completedItem: DriveItem? = nil
            if totalWireSize == 0 {
                let result = try await client.uploadResumableChunk(
                    sessionURL: sessionURL,
                    chunkData: Data(),
                    offset: 0,
                    totalSize: 0
                )
                record.offset = result.nextOffset
                completedItem = result.completedItem
            } else {
                while record.offset < totalWireSize {
                    if let latest = try await store.fetchUpload(id: record.id), latest.cancelRequested {
                        try await store.deleteUpload(id: record.id)
                        return
                    }

                    let start = Int(record.offset)
                    let end = min(start + Self.uploadQuantumSize, Int(totalWireSize))
                    let chunk = payloadData.subdata(in: start..<end)

                    let chunkStartClock = ContinuousClock.now
                    let result = try await client.uploadResumableChunk(
                        sessionURL: sessionURL,
                        chunkData: chunk,
                        offset: record.offset,
                        totalSize: totalWireSize
                    )
                    record.offset = result.nextOffset
                    completedItem = result.completedItem
                    try await store.upsertUpload(record)

                    if case .fixed(let mbps) = bandwidthMode, mbps > 0 {
                        let bytesPerSec = (mbps * 1_000_000.0) / 8.0
                        let expectedSeconds = Double(chunk.count) / bytesPerSec
                        let elapsed = chunkStartClock.duration(to: .now)
                        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                        if expectedSeconds > elapsedSeconds {
                            let sleepNanos = UInt64((expectedSeconds - elapsedSeconds) * 1_000_000_000)
                            try? await Task.sleep(nanoseconds: sleepNanos)
                        }
                    }
                }
            }

            record.state = .committing
            try await store.upsertUpload(record)

            if var item = completedItem {
                item.name = record.name
                item.size = Int64(rawData.count)
                item.isEncrypted = record.encrypt
                try await store.upsertItem(item)
                try await store.recordLocalChange(driveId: item.driveId)
                record.resultDriveId = item.driveId
                record.resultVersion = item.version
                record.resultHash = item.md5
            }

            record.state = .done
            try await store.upsertUpload(record)
            DarwinNotifier.shared.post(.changed)
        } catch {
            record.attempts += 1
            record.state = .failed
            record.lastError = error.localizedDescription
            record.retryAt = Date().addingTimeInterval(min(300, pow(2.0, Double(record.attempts)))).timeIntervalSince1970
            try? await store.upsertUpload(record)
            DarwinNotifier.shared.post(.changed)
        }
    }
}

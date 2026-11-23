import CryptoKit
import Foundation

/// Loads registered accounts, Keychain master keys, preferences, and cross-process
/// Darwin/network observers into a `DriveVolume`.
public enum DriveVolumeBootstrapper {
    public static func loadRegisteredAccounts(into driveVolume: DriveVolume, cache: ChunkCache?) async {
        let regURL = OpenDrivePaths.accountsRegistryURL
        guard let cache = cache ?? (try? ChunkCache(maxBytes: SharedSettings.shared.maxCacheBytes)) else {
            return
        }
        let settings = SharedSettings.shared
        await cache.setMaxBytes(settings.maxCacheBytes)

        let accounts: [CloudAccount]
        if let data = try? Data(contentsOf: regURL),
           let decoded = try? JSONDecoder().decode([CloudAccount].self, from: data) {
            accounts = decoded
        } else {
            accounts = []
        }

        await driveVolume.unregisterRemovedAccounts(keepingIds: Set(accounts.map(\.id)))

        let clientId = settings.googleClientId
        let rawSecret = settings.googleClientSecret
        let clientSecret = rawSecret.isEmpty ? nil : rawSecret
        let bandwidthMode = settings.bandwidthMode
        let pauseOnMetered = settings.pauseOnMetered
        let isMetered = NetworkPathObserver.shared.isMetered
        let isOffline = NetworkPathObserver.shared.isOffline

        var updatedAccounts = accounts
        var modifiedRegistry = false

        for idx in updatedAccounts.indices {
            var acc = updatedAccounts[idx]
            guard let store = try? MetadataStore(databaseURL: OpenDrivePaths.databaseURL(for: acc.id)) else {
                continue
            }
            let client = GoogleDriveClient(accountId: acc.id, clientId: clientId, clientSecret: clientSecret)
            if acc.wholeDrive && (acc.rootId == nil || acc.rootId == "root"),
               let canonicalRootId = try? await client.resolveRootFolderId(),
               canonicalRootId != "root" {
                acc.rootId = canonicalRootId
                updatedAccounts[idx] = acc
                modifiedRegistry = true
            }
            try? await store.upsertAccount(acc)
            let reader = RangeReader(cache: cache) { driveId, offset, length in
                try await client.downloadByteRange(driveId: driveId, offset: offset, length: length)
            }
            let uploader = UploadEngine(store: store, client: client)
            await uploader.setBandwidthMode(bandwidthMode)
            await uploader.setPauseOnMetered(pauseOnMetered)
            await uploader.setNetworkState(isMetered: isMetered, isOffline: isOffline)

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
                cache: cache,
                masterKey: masterKey
            )
            await driveVolume.registerCloudStack(stack)
        }

        if modifiedRegistry, let encoded = try? JSONEncoder().encode(updatedAccounts) {
            try? OpenDrivePaths.writePrivateFile(encoded, to: regURL)
        }

        await driveVolume.setBandwidthModeForAll(bandwidthMode)
        await driveVolume.setPauseOnMeteredForAll(pauseOnMetered)
    }

    public static func attachLiveObservers(
        driveVolume: DriveVolume,
        cache: ChunkCache?,
        onUpdated: (@Sendable () async -> Void)? = nil
    ) {
        DarwinNotifier.shared.observe(.signal) {
            Task {
                await Self.loadRegisteredAccounts(into: driveVolume, cache: cache)
                await driveVolume.syncAllAccountsOnce()
                await onUpdated?()
            }
        }
        DarwinNotifier.shared.observe(.cancelUpload) {
            Task {
                await driveVolume.syncAllAccountsOnce()
                await onUpdated?()
            }
        }
        DarwinNotifier.shared.observe(.pulled) {
            Task {
                await onUpdated?()
            }
        }
        DarwinNotifier.shared.observe(.clearCache) {
            Task {
                await cache?.clearAll()
            }
        }
        NetworkPathObserver.shared.observe { isMetered, isOffline in
            Task {
                await driveVolume.setNetworkStateForAll(isMetered: isMetered, isOffline: isOffline)
            }
        }
    }
}

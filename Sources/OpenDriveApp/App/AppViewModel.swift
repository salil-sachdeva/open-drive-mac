import AppKit
import CryptoKit
import Foundation
import OpenDriveCore
import ServiceManagement
import UniformTypeIdentifiers

/// Central observable state coordinator for the Open Drive menu-bar app, Settings window,
/// global search palette, and floating upload HUD pill.
@MainActor
public final class OpenDriveAppViewModel: ObservableObject {
    @Published public var accounts: [CloudAccount] = []
    @Published public var unlockedAccountIds: Set<String> = []
    @Published public var pendingUploads: [UploadRecord] = []
    @Published public var recentFolders: [RecentFolderRecord] = []
    @Published public var searchResults: [(account: CloudAccount, item: DriveItem)] = []
    @Published public var searchQuery: String = ""
    @Published public var googleClientId: String = UserDefaults.standard.string(forKey: AppConstants.DefaultsKey.googleClientId) ?? ""
    @Published public var googleClientSecret: String = UserDefaults.standard.string(forKey: AppConstants.DefaultsKey.googleClientSecret) ?? ""
    @Published public var wholeDriveMode: Bool = false
    @Published public var encryptionEnabled: Bool = false
    @Published public var vaultPassphrase: String = ""
    @Published public var recoveryWords: [String] = []
    @Published public var isOAuthInProgress: Bool = false
    @Published public var statusBanner: String = "Open Drive (Google Drive + FSKit)"
    @Published public var hudAlertMessage: String? = nil
    @Published public var isNetworkMetered: Bool = false
    @Published public var isNetworkOffline: Bool = false
    @Published public var pauseOnMetered: Bool = true
    @Published public var bandwidthLimitMbps: Double = 0
    @Published public var maxCacheGiB: Double = 5.0
    @Published public var searchHotkeyEnabled: Bool = true
    @Published public var launchAtLogin: Bool = false

    public let mountManager = MountManager()
    public private(set) var paletteController: PalettePanelController?
    public private(set) var hudController: HUDPillWindowController?
    private var serviceProvider: FinderServiceProvider?

    public init() {
        loadAccounts()
        self.paletteController = PalettePanelController(viewModel: self)
        self.hudController = HUDPillWindowController(viewModel: self)
        let sp = FinderServiceProvider(viewModel: self)
        self.serviceProvider = sp
        NSApplication.shared.servicesProvider = sp

        Task {
            await refreshUnlockedVaultStates()
            await refreshPendingUploads()
            await refreshRecentFolders()
        }

        DarwinNotifier.shared.observe(.changed) { [weak self] in
            Task { @MainActor in
                await self?.refreshPendingUploads()
                await self?.refreshRecentFolders()
            }
        }
        DarwinNotifier.shared.observe(.pulled) { [weak self] in
            Task { @MainActor in
                await self?.performPaletteSearch()
            }
        }
        DarwinNotifier.shared.observe(.ejectGuard) { [weak self] in
            Task { @MainActor in
                self?.hudAlertMessage = "Cannot unmount while files are still uploading."
                self?.hudController?.updateVisibility(hasActiveUploads: true, alertMessage: self?.hudAlertMessage)
            }
        }

        NetworkPathObserver.shared.observe { [weak self] metered, offline in
            Task { @MainActor in
                self?.isNetworkMetered = metered
                self?.isNetworkOffline = offline
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if !MountManager.hasActiveUploadsSync() {
                Task { @MainActor in
                    self.mountManager.unmountFilesystem()
                }
            }
        }
    }

    // MARK: - Account Registry & Vault State

    public func loadAccounts() {
        let url = OpenDrivePaths.accountsRegistryURL
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([CloudAccount].self, from: data) {
            self.accounts = decoded
        }
    }

    public func saveAccounts() {
        let url = OpenDrivePaths.accountsRegistryURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(accounts) {
            try? data.write(to: url, options: .atomic)
        }
        DarwinNotifier.shared.post(.signal)
    }

    public func refreshUnlockedVaultStates() async {
        var unlocked: Set<String> = []
        for acc in accounts {
            if !acc.encryptionEnabled {
                unlocked.insert(acc.id)
            } else if (try? await KeychainStore.shared.loadMasterKey(for: acc.id)) != nil {
                unlocked.insert(acc.id)
            }
        }
        self.unlockedAccountIds = unlocked
    }

    // MARK: - Browser OAuth 2.0 PKCE + Remote `.fd-meta` Vault Bootstrap

    public func signInWithGoogleBrowser(displayName: String) async {
        let trimmedClientId = googleClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientId.isEmpty else {
            statusBanner = "Enter your Google OAuth Client ID first"
            return
        }

        isOAuthInProgress = true
        defer { isOAuthInProgress = false }

        do {
            let loopback = try GoogleOAuthLoopbackServer()
            let pkce = GoogleOAuth.PKCEChallenge()
            let authURL = GoogleOAuth.buildAuthorizationURL(
                clientId: trimmedClientId,
                redirectURI: loopback.redirectURI,
                pkce: pkce
            )

            statusBanner = "Waiting for Google Sign-In in browser..."
            NSWorkspace.shared.open(authURL)

            let code = try await loopback.waitForAuthorizationCode(expectedState: pkce.state)
            statusBanner = "Exchanging OAuth code for tokens..."

            let secret = googleClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens = try await GoogleOAuth.exchangeCodeForTokens(
                code: code,
                clientId: trimmedClientId,
                clientSecret: secret.isEmpty ? nil : secret,
                redirectURI: loopback.redirectURI,
                codeVerifier: pkce.verifier
            )

            let accountId = UUID().uuidString.lowercased()
            try await KeychainStore.shared.saveOAuthTokens(tokens, for: accountId)

            let client = GoogleDriveClient(
                accountId: accountId,
                clientId: trimmedClientId,
                clientSecret: secret.isEmpty ? nil : secret
            )
            let email = (try? await client.fetchUserEmail()) ?? nil
            let workspace = try await client.ensureWorkspace(wholeDrive: wholeDriveMode)

            var account = CloudAccount(
                id: accountId,
                displayName: displayName.isEmpty ? AppConstants.defaultAccountName : displayName,
                email: email,
                rootId: workspace.rootId,
                trashId: workspace.trashId,
                changesPageToken: workspace.startPageToken,
                encryptionEnabled: encryptionEnabled,
                rootCreatedAt: Date().timeIntervalSince1970,
                wholeDrive: wholeDriveMode
            )

            var activeMasterKey: SymmetricKey? = nil

            if let existingRemoteMeta = try? await client.fetchKeyBundle(rootId: workspace.rootId) {
                account.encryptionEnabled = true
                account.metaId = existingRemoteMeta.metaDriveId
                let metaURL = OpenDrivePaths.appSupportRootURL.appendingPathComponent("\(accountId)-\(OpenDrivePaths.metaFileName)")
                try? JSONEncoder().encode(existingRemoteMeta.bundle).write(to: metaURL, options: .atomic)

                if !vaultPassphrase.isEmpty,
                   let mkKey = try? VaultCrypto.unlockMasterKey(passphrase: vaultPassphrase, bundle: existingRemoteMeta.bundle) {
                    let mkData = mkKey.withUnsafeBytes { Data($0) }
                    try? await KeychainStore.shared.saveMasterKey(mkData, for: accountId)
                    activeMasterKey = mkKey
                }
            } else if encryptionEnabled && !vaultPassphrase.isEmpty {
                let (bundle, words, mkData) = try VaultCrypto.createKeyBundle(passphrase: vaultPassphrase)
                try await KeychainStore.shared.saveMasterKey(mkData, for: accountId)
                activeMasterKey = SymmetricKey(data: mkData)
                self.recoveryWords = words

                let metaURL = OpenDrivePaths.appSupportRootURL.appendingPathComponent("\(accountId)-\(OpenDrivePaths.metaFileName)")
                try JSONEncoder().encode(bundle).write(to: metaURL, options: .atomic)

                if let remoteMetaId = try? await client.uploadKeyBundle(bundle, rootId: workspace.rootId, existingMetaId: nil) {
                    account.metaId = remoteMetaId
                }
            }

            let store = try MetadataStore(databaseURL: OpenDrivePaths.databaseURL(for: accountId))
            try await store.upsertAccount(account)

            if let cache = try? ChunkCache() {
                let syncer = SyncEngine(accountId: accountId, store: store, client: client, cache: cache)
                _ = try? await syncer.pullRemoteChanges(masterKey: activeMasterKey)
            }

            accounts.append(account)
            saveAccounts()
            await refreshUnlockedVaultStates()
            statusBanner = "Connected \(account.displayName)\(email.map { " (\($0))" } ?? "")"
        } catch {
            statusBanner = "OAuth failed: \(error.localizedDescription)"
        }
    }

    public func addGoogleDriveAccount(displayName: String, email: String) async {
        let id = UUID().uuidString.lowercased()
        var account = CloudAccount(
            id: id,
            displayName: displayName.isEmpty ? AppConstants.defaultAccountName : displayName,
            email: email.isEmpty ? nil : email,
            rootId: AppConstants.defaultRootId,
            encryptionEnabled: encryptionEnabled,
            rootCreatedAt: Date().timeIntervalSince1970,
            wholeDrive: wholeDriveMode
        )

        if encryptionEnabled && !vaultPassphrase.isEmpty {
            if let (bundle, words, mkData) = try? VaultCrypto.createKeyBundle(passphrase: vaultPassphrase) {
                try? await KeychainStore.shared.saveMasterKey(mkData, for: id)
                self.recoveryWords = words
                let metaURL = OpenDrivePaths.appSupportRootURL.appendingPathComponent("\(id)-\(OpenDrivePaths.metaFileName)")
                try? JSONEncoder().encode(bundle).write(to: metaURL, options: .atomic)
                account.metaId = metaURL.lastPathComponent
            }
        }

        if let store = try? MetadataStore(databaseURL: OpenDrivePaths.databaseURL(for: id)) {
            try? await store.upsertAccount(account)
        }
        accounts.append(account)
        saveAccounts()
        await refreshUnlockedVaultStates()
        statusBanner = "Connected \(account.displayName)"
    }

    public func removeAccount(_ account: CloudAccount) async {
        accounts.removeAll { $0.id == account.id }
        try? await KeychainStore.shared.deleteOAuthTokens(for: account.id)
        try? await KeychainStore.shared.deleteMasterKey(for: account.id)
        saveAccounts()
        await refreshUnlockedVaultStates()
        statusBanner = "Removed \(account.displayName)"
    }

    public func unlockVault(for account: CloudAccount, secretInput: String) async -> Bool {
        let metaURL = OpenDrivePaths.appSupportRootURL.appendingPathComponent("\(account.id)-\(OpenDrivePaths.metaFileName)")
        guard let data = try? Data(contentsOf: metaURL),
              let bundle = try? JSONDecoder().decode(KeyBundle.self, from: data) else {
            statusBanner = "Missing local .fd-meta bundle for \(account.displayName)"
            return false
        }

        let words = secretInput.split(whereSeparator: \.isWhitespace).map(String.init)
        let mkKey: SymmetricKey?
        if words.count == 24 {
            mkKey = try? VaultCrypto.unlockMasterKey(recoveryWords: words, bundle: bundle)
        } else {
            mkKey = try? VaultCrypto.unlockMasterKey(passphrase: secretInput, bundle: bundle)
        }

        guard let unwrappedKey = mkKey else {
            statusBanner = "Invalid passphrase or recovery phrase"
            return false
        }

        let mkData = unwrappedKey.withUnsafeBytes { Data($0) }
        try? await KeychainStore.shared.saveMasterKey(mkData, for: account.id)
        await refreshUnlockedVaultStates()
        DarwinNotifier.shared.post(.signal)
        statusBanner = "Unlocked vault for \(account.displayName)"
        return true
    }

    public func exportRecoveryKeySheet(for accountName: String, email: String?) {
        guard !recoveryWords.isEmpty else { return }
        let savePanel = NSSavePanel()
        savePanel.title = "Save Open Drive Recovery Key"
        savePanel.nameFieldStringValue = "open drive recovery key.pdf"
        savePanel.allowedContentTypes = [.pdf]
        if savePanel.runModal() == .OK, let targetURL = savePanel.url {
            do {
                try VaultCrypto.exportRecoveryKeyPDF(
                    to: targetURL,
                    accountName: accountName,
                    email: email,
                    words: recoveryWords
                )
                statusBanner = "Saved recovery key PDF to \(targetURL.lastPathComponent)"
            } catch {
                statusBanner = "Failed to save PDF: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Search, Pinning, Drag-and-Drop Uploads & Queue Control

    public func performPaletteSearch() async {
        var combined: [(account: CloudAccount, item: DriveItem)] = []
        for account in accounts {
            if let store = try? MetadataStore(databaseURL: OpenDrivePaths.databaseURL(for: account.id)),
               let hits = try? await store.searchItems(query: searchQuery, limit: 30) {
                for hit in hits {
                    combined.append((account: account, item: hit))
                }
            }
        }
        searchResults = combined
    }

    public func togglePin(item: DriveItem, in account: CloudAccount) async {
        guard let store = try? MetadataStore(databaseURL: OpenDrivePaths.databaseURL(for: account.id)) else { return }
        try? await store.setPinned(driveId: item.driveId, pinned: !item.pinned)
        await performPaletteSearch()
    }

    public func localVFSURL(for item: DriveItem, in account: CloudAccount) -> URL {
        OpenDrivePaths.mountRootURL
            .appendingPathComponent(account.displayName, isDirectory: true)
            .appendingPathComponent(item.shownAs, isDirectory: item.isFolder)
    }

    public func refreshPendingUploads() async {
        var all: [UploadRecord] = []
        for account in accounts {
            if let store = try? MetadataStore(databaseURL: OpenDrivePaths.databaseURL(for: account.id)),
               let list = try? await store.fetchPendingUploads() {
                all.append(contentsOf: list)
            }
        }
        pendingUploads = all
        if all.isEmpty {
            hudAlertMessage = nil
        }
        hudController?.updateVisibility(hasActiveUploads: !all.isEmpty, alertMessage: hudAlertMessage)
    }

    public func refreshRecentFolders() async {
        var all: [RecentFolderRecord] = []
        for account in accounts {
            if let store = try? MetadataStore(databaseURL: OpenDrivePaths.databaseURL(for: account.id)),
               let recent = try? await store.listRecentFolders(limit: 8) {
                all.append(contentsOf: recent)
            }
        }
        recentFolders = all
    }

    public func enqueueDroppedFiles(urls: [URL], targetFolderId: String?) async {
        guard let primaryAccount = accounts.first,
              let store = try? MetadataStore(databaseURL: OpenDrivePaths.databaseURL(for: primaryAccount.id)) else {
            statusBanner = "Connect a Google Drive account before dropping files"
            return
        }
        let parentId = targetFolderId ?? primaryAccount.rootId ?? AppConstants.defaultRootId
        let client = GoogleDriveClient(
            accountId: primaryAccount.id,
            clientId: googleClientId,
            clientSecret: googleClientSecret.isEmpty ? nil : googleClientSecret
        )
        let uploader = UploadEngine(store: store, client: client)

        for fileURL in urls {
            let stagedURL = OpenDrivePaths.scratchCacheURL.appendingPathComponent("\(UUID().uuidString)-\(fileURL.lastPathComponent)")
            try? FileManager.default.createDirectory(at: OpenDrivePaths.scratchCacheURL, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: fileURL, to: stagedURL)
            _ = try? await uploader.enqueueUpload(
                localURL: stagedURL,
                parentId: parentId,
                targetDriveId: nil,
                name: fileURL.lastPathComponent,
                encrypt: primaryAccount.encryptionEnabled
            )
        }
        await refreshPendingUploads()
        statusBanner = "Queued \(urls.count) file(s) for upload"
        DarwinNotifier.shared.post(.signal)
    }

    public func cancelUpload(_ record: UploadRecord) async {
        for account in accounts {
            if let store = try? MetadataStore(databaseURL: OpenDrivePaths.databaseURL(for: account.id)) {
                try? await store.requestCancelUpload(id: record.id)
            }
        }
        DarwinNotifier.shared.post(.cancelUpload)
        await refreshPendingUploads()
    }

    public func clearChunkCache() {
        DarwinNotifier.shared.post(.clearCache)
        statusBanner = "Purged local chunk cache"
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
        if enabled {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }
}

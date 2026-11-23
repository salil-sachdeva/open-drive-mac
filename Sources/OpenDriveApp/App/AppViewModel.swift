import AppKit
import Combine
import CryptoKit
import Foundation
import OpenDriveCore
import ServiceManagement
import UniformTypeIdentifiers

/// Sidebar destinations for the main Open Drive window.
public enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case overview
    case accounts
    case uploads
    case offline

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: return "Overview"
        case .accounts: return "Accounts"
        case .uploads: return "Uploads"
        case .offline: return "Offline Files"
        }
    }

    public var symbolName: String {
        switch self {
        case .overview: return "externaldrive.badge.icloud"
        case .accounts: return "person.2.circle"
        case .uploads: return "arrow.up.circle"
        case .offline: return "pin.circle"
        }
    }
}

/// Tabs in the native macOS Settings window (`⌘,`).
public enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case accounts
    case network

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: return "General"
        case .accounts: return "Accounts & Vault"
        case .network: return "Network"
        }
    }

    public var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .accounts: return "lock.icloud"
        case .network: return "network"
        }
    }
}

/// A command-palette search result paired with its resolved relative folder path.
public struct PaletteSearchHit: Identifiable, Sendable {
    public let account: CloudAccount
    public let item: DriveItem
    public let relativePathComponents: [String]

    public var id: String {
        "\(account.id):\(item.driveId)"
    }

    public var parentFolderBreadcrumb: String {
        relativePathComponents.dropLast().joined(separator: " / ")
    }
}

/// Central observable state coordinator for the Open Drive menu-bar app, Settings window,
/// global search palette, and floating upload HUD pill.
@MainActor
public final class OpenDriveAppViewModel: ObservableObject {
    @Published public var selectedSidebarItem: SidebarSection = .overview
    @Published public var selectedSettingsTab: SettingsTab = .general
    @Published public var accounts: [CloudAccount] = []
    @Published public var unlockedAccountIds: Set<String> = []
    @Published public var pendingUploads: [UploadRecord] = []
    @Published public var pinnedItems: [PaletteSearchHit] = []
    @Published public var recentFolders: [RecentFolderRecord] = []
    @Published public var recentFoldersByAccount: [String: [RecentFolderRecord]] = [:]
    @Published public var searchResults: [PaletteSearchHit] = []
    @Published public var searchQuery: String = ""
    @Published public var googleClientId: String {
        didSet {
            guard !isSeedMode else { return }
            SharedSettings.shared.googleClientId = googleClientId
            DarwinNotifier.shared.post(.signal)
        }
    }
    @Published public var googleClientSecret: String {
        didSet {
            guard !isSeedMode else { return }
            SharedSettings.shared.googleClientSecret = googleClientSecret
            DarwinNotifier.shared.post(.signal)
        }
    }
    @Published public var wholeDriveMode: Bool = true
    @Published public var encryptionEnabled: Bool = false
    @Published public var vaultPassphrase: String = ""
    @Published public var recoveryWords: [String] = []
    @Published public var storageQuotasByAccountId: [String: CloudStorageQuota] = [:]
    @Published public var switchingScopeAccountIds: Set<String> = []
    @Published public var isOAuthInProgress: Bool = false
    @Published public var oauthStatusMessage: String? = nil
    @Published public var oauthStatusIsError: Bool = false
    @Published public var statusBanner: String = "Open Drive (Google Drive + FSKit)"
    @Published public var hudAlertMessage: String? = nil
    @Published public var isNetworkMetered: Bool = false
    @Published public var isNetworkOffline: Bool = false
    @Published public var pauseOnMetered: Bool {
        didSet {
            guard !isSeedMode else { return }
            SharedSettings.shared.pauseOnMetered = pauseOnMetered
            DarwinNotifier.shared.post(.signal)
        }
    }
    @Published public var bandwidthLimitMbps: Double {
        didSet {
            guard !isSeedMode else { return }
            SharedSettings.shared.bandwidthLimitMbps = bandwidthLimitMbps
            DarwinNotifier.shared.post(.signal)
        }
    }
    @Published public var maxCacheGiB: Double {
        didSet {
            guard !isSeedMode else { return }
            SharedSettings.shared.maxCacheGiB = maxCacheGiB
            DarwinNotifier.shared.post(.signal)
        }
    }
    @Published public var searchHotkeyEnabled: Bool {
        didSet {
            guard !isSeedMode else { return }
            SharedSettings.shared.searchHotkeyEnabled = searchHotkeyEnabled
        }
    }
    @Published public var hideDockIconWhenClosed: Bool {
        didSet {
            guard !isSeedMode else { return }
            SharedSettings.shared.hideDockIconWhenClosed = hideDockIconWhenClosed
            OpenDriveAppDelegate.shared?.syncDockVisibility()
        }
    }
    @Published public var mountBackendMode: MountBackendMode {
        didSet {
            guard !isSeedMode else { return }
            SharedSettings.shared.mountBackendMode = mountBackendMode
            if mountManager.isMounted && !accounts.isEmpty {
                Task { await mountManager.switchBackendAndRemount() }
            }
        }
    }
    @Published public var mountedDriveName: String
    @Published public var launchAtLogin: Bool = false
    @Published public var launchAtLoginRequiresApproval: Bool = false
    @Published public var launchAtLoginError: String? = nil

    public let isSeedMode: Bool
    public var hasBundledOAuthCredentials: Bool {
        isSeedMode || SharedSettings.shared.hasBundledGoogleOAuthCredentials
    }

    public var aggregatedStorageQuota: CloudStorageQuota? {
        var totalLimit: Int64 = 0
        var totalUsage: Int64 = 0
        var hasFinite = false
        var hasAnyQuota = false

        for account in accounts {
            guard let quota = storageQuotasByAccountId[account.id] else { continue }
            hasAnyQuota = true
            if let total = quota.totalBytes {
                hasFinite = true
                totalLimit += total
            }
            if quota.usage != nil {
                totalUsage += quota.usedBytes
            }
        }
        guard hasAnyQuota else { return nil }
        return CloudStorageQuota(limit: hasFinite ? totalLimit : nil, usage: totalUsage)
    }

    public let mountManager: MountManager
    public private(set) var paletteController: PalettePanelController?
    public private(set) var hudController: HUDPillWindowController?
    private var serviceProvider: FinderServiceProvider?
    private var activeLoopbackServer: GoogleOAuthLoopbackServer?
    private var mountManagerCancellable: AnyCancellable?

    public init(seedMode: Bool = ProcessInfo.processInfo.environment["APP_SEED"] == "1") {
        self.isSeedMode = seedMode
        self.mountManager = MountManager(skipSystemChecks: seedMode)

        if seedMode {
            self.googleClientId = "1234567890-sample.apps.googleusercontent.com"
            self.googleClientSecret = ""
            self.pauseOnMetered = true
            self.bandwidthLimitMbps = 0
            self.maxCacheGiB = 10
            self.searchHotkeyEnabled = true
            self.hideDockIconWhenClosed = true
            self.mountBackendMode = .virtualDiskNFS
            self.mountedDriveName = OpenDrivePaths.defaultDriveName
            populateSeedData()
            self.paletteController = PalettePanelController(viewModel: self)
            return
        }

        self.googleClientId = SharedSettings.shared.googleClientId
        self.googleClientSecret = SharedSettings.shared.googleClientSecret
        self.pauseOnMetered = SharedSettings.shared.pauseOnMetered
        self.bandwidthLimitMbps = SharedSettings.shared.bandwidthLimitMbps
        self.maxCacheGiB = SharedSettings.shared.maxCacheGiB
        self.searchHotkeyEnabled = SharedSettings.shared.searchHotkeyEnabled
        self.hideDockIconWhenClosed = SharedSettings.shared.hideDockIconWhenClosed
        self.mountBackendMode = SharedSettings.shared.mountBackendMode
        self.mountedDriveName = SharedSettings.shared.mountedDriveName
        OpenDriveAppDelegate.pendingMountManager = self.mountManager
        OpenDriveAppDelegate.shared?.mountManager = self.mountManager
        refreshLaunchAtLoginStatus()

        loadAccounts()
        self.mountManagerCancellable = mountManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        self.paletteController = PalettePanelController(viewModel: self)
        self.hudController = HUDPillWindowController(viewModel: self)
        let sp = FinderServiceProvider(viewModel: self)
        self.serviceProvider = sp
        NSApplication.shared.servicesProvider = sp

        if !accounts.isEmpty && !mountManager.isMounted {
            mountManager.mountFilesystem()
        }

        Task {
            await resolveCanonicalWholeDriveRootsIfNeeded()
            await refreshUnlockedVaultStates()
            await refreshStorageQuotas()
            await refreshPendingUploads()
            await refreshRecentFolders()
            await refreshPinnedItems()
        }

        DarwinNotifier.shared.observe(.signal) { [weak self] in
            Task { @MainActor in
                await self?.refreshStorageQuotas()
            }
        }
        DarwinNotifier.shared.observe(.changed) { [weak self] in
            Task { @MainActor in
                await self?.refreshPendingUploads()
                await self?.refreshRecentFolders()
                await self?.refreshPinnedItems()
                await self?.refreshStorageQuotas()
            }
        }
        DarwinNotifier.shared.observe(.pulled) { [weak self] in
            Task { @MainActor in
                await self?.performPaletteSearch()
                await self?.refreshPinnedItems()
                await self?.refreshStorageQuotas()
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
    }

    private func populateSeedData() {
        let personal = CloudAccount(
            id: "seed-personal",
            displayName: "Personal Drive",
            email: "alex@gmail.com",
            rootId: "root-personal",
            encryptionEnabled: false,
            wholeDrive: true
        )
        let vault = CloudAccount(
            id: "seed-vault",
            displayName: "Private Vault",
            email: "vault@acme.example",
            rootId: "root-vault",
            encryptionEnabled: true,
            wholeDrive: true
        )
        self.accounts = [personal, vault]
        self.unlockedAccountIds = [personal.id, vault.id]
        self.storageQuotasByAccountId = [
            personal.id: CloudStorageQuota(limit: 2_000_000_000_000, usage: 342_500_000_000),
            vault.id: CloudStorageQuota(limit: 100_000_000_000, usage: 18_250_000_000)
        ]

        let upload1 = UploadRecord(
            id: "seed-up-1",
            localPath: "/tmp/Quarterly-Deck.key",
            parentId: "root-personal",
            name: "Quarterly-Deck.key",
            size: 48_234_496,
            mime: "application/octet-stream",
            state: .uploading,
            offset: 16_777_216,
            attempts: 1,
            encrypt: false
        )
        let upload2 = UploadRecord(
            id: "seed-up-2",
            localPath: "/tmp/Financials-2026.pdf",
            parentId: "root-vault",
            name: "Financials-2026.pdf",
            size: 12_582_912,
            mime: "application/pdf",
            state: .paused,
            offset: 4_194_304,
            attempts: 2,
            lastError: "Paused on Personal Hotspot / Metered Network",
            pausedReason: .metered,
            encrypt: true
        )
        self.pendingUploads = [upload1, upload2]

        let pinned1 = PaletteSearchHit(
            account: personal,
            item: DriveItem(
                driveId: "seed-item-1",
                parentId: "folder-design",
                name: "Launch Checklist.md",
                isFolder: false,
                size: 24_576,
                mime: "text/markdown",
                pinned: true
            ),
            relativePathComponents: ["Product", "Launch Checklist.md"]
        )
        let pinned2 = PaletteSearchHit(
            account: personal,
            item: DriveItem(
                driveId: "seed-item-2",
                parentId: "folder-media",
                name: "Demo Walk-Through.mov",
                isFolder: false,
                size: 184_549_376,
                mime: "video/quicktime",
                pinned: true
            ),
            relativePathComponents: ["Videos", "Demo Walk-Through.mov"]
        )
        let pinned3 = PaletteSearchHit(
            account: vault,
            item: DriveItem(
                driveId: "seed-item-3",
                parentId: "folder-legal",
                name: "Tax Return 2025.pdf",
                isFolder: false,
                size: 3_670_016,
                mime: "application/pdf",
                isEncrypted: true,
                pinned: true
            ),
            relativePathComponents: ["Legal", "Taxes", "Tax Return 2025.pdf"]
        )
        self.pinnedItems = [pinned1, pinned2, pinned3]
        self.searchResults = [pinned1, pinned2, pinned3]

        let folder1 = RecentFolderRecord(id: "folder-design", name: "Product")
        let folder2 = RecentFolderRecord(id: "folder-legal", name: "Legal / Taxes")
        self.recentFolders = [folder1, folder2]
        self.recentFoldersByAccount = [
            personal.id: [folder1],
            vault.id: [folder2]
        ]
        self.statusBanner = "Connected Personal Drive & Private Vault"
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
        if let data = try? JSONEncoder().encode(accounts) {
            try? OpenDrivePaths.writePrivateFile(data, to: url)
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

    // MARK: - Browser OAuth 2.0 PKCE + Remote `.od-meta` Vault Bootstrap

    public func cancelGoogleSignIn() {
        activeLoopbackServer?.cancel()
        activeLoopbackServer = nil
        isOAuthInProgress = false
        oauthStatusIsError = false
        oauthStatusMessage = "Sign-in cancelled."
    }

    public func signInWithGoogleBrowser(displayName: String) async {
        guard !isSeedMode else {
            oauthStatusIsError = false
            oauthStatusMessage = "Sample preview mode — sign-in is disabled."
            return
        }

        let trimmedClientId = googleClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientId.isEmpty else {
            statusBanner = "Enter your Google OAuth Client ID first"
            oauthStatusIsError = true
            oauthStatusMessage = "Enter your Google OAuth Client ID first. Create a Desktop app OAuth client in Google Cloud Console and paste its Client ID and Client Secret above."
            return
        }

        isOAuthInProgress = true
        oauthStatusIsError = false
        oauthStatusMessage = "Opening Google Sign-In in your default browser…"
        defer {
            isOAuthInProgress = false
            activeLoopbackServer = nil
        }

        do {
            let loopback = try GoogleOAuthLoopbackServer()
            self.activeLoopbackServer = loopback
            let pkce = GoogleOAuth.PKCEChallenge()
            let authURL = GoogleOAuth.buildAuthorizationURL(
                clientId: trimmedClientId,
                redirectURI: loopback.redirectURI,
                pkce: pkce
            )

            guard NSWorkspace.shared.open(authURL) else {
                throw GoogleDriveError.oauthFailed("Could not open your default web browser. Check macOS Default Web Browser settings.")
            }

            statusBanner = "Waiting for Google Sign-In in browser..."
            oauthStatusMessage = "Waiting for Google Sign-In in your browser…"

            let code = try await loopback.waitForAuthorizationCode(expectedState: pkce.state)
            statusBanner = "Exchanging OAuth code for tokens..."
            oauthStatusMessage = "Exchanging authorization code for tokens…"

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

            let safeAccountId = OpenDrivePaths.sanitizeAccountId(accountId)
            let metaURL = OpenDrivePaths.appSupportRootURL.appendingPathComponent("\(safeAccountId)-\(OpenDrivePaths.metaFileName)")

            if let existingRemoteMeta = try? await client.fetchKeyBundle(rootId: workspace.rootId) {
                account.encryptionEnabled = true
                account.metaId = existingRemoteMeta.metaDriveId
                if let bundleData = try? JSONEncoder().encode(existingRemoteMeta.bundle) {
                    try? OpenDrivePaths.writePrivateFile(bundleData, to: metaURL)
                }

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

                let bundleData = try JSONEncoder().encode(bundle)
                try OpenDrivePaths.writePrivateFile(bundleData, to: metaURL)

                if let remoteMetaId = try? await client.uploadKeyBundle(bundle, rootId: workspace.rootId, existingMetaId: nil) {
                    account.metaId = remoteMetaId
                }
            }
            self.vaultPassphrase = ""

            let store = try MetadataStore(databaseURL: OpenDrivePaths.databaseURL(for: accountId))
            try await store.upsertAccount(account)

            if let cache = try? ChunkCache() {
                let syncer = SyncEngine(accountId: accountId, store: store, client: client, cache: cache)
                _ = try? await syncer.pullRemoteChanges(masterKey: activeMasterKey)
            }

            accounts.append(account)
            saveAccounts()
            await refreshUnlockedVaultStates()
            await refreshStorageQuotas()
            if !mountManager.isMounted {
                mountManager.mountFilesystem()
            }
            statusBanner = "Connected \(account.displayName)\(email.map { " (\($0))" } ?? "")"
            oauthStatusIsError = false
            oauthStatusMessage = "Connected \(account.displayName)\(email.map { " (\($0))" } ?? "")."
        } catch {
            statusBanner = "OAuth failed: \(error.localizedDescription)"
            oauthStatusIsError = true
            oauthStatusMessage = "Sign-in failed: \(error.localizedDescription)"
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
                let safeId = OpenDrivePaths.sanitizeAccountId(id)
                let metaURL = OpenDrivePaths.appSupportRootURL.appendingPathComponent("\(safeId)-\(OpenDrivePaths.metaFileName)")
                if let bundleData = try? JSONEncoder().encode(bundle) {
                    try? OpenDrivePaths.writePrivateFile(bundleData, to: metaURL)
                }
                account.metaId = metaURL.lastPathComponent
            }
            self.vaultPassphrase = ""
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
        storageQuotasByAccountId.removeValue(forKey: account.id)
        try? await KeychainStore.shared.deleteOAuthTokens(for: account.id)
        try? await KeychainStore.shared.deleteMasterKey(for: account.id)

        let dbURL = OpenDrivePaths.databaseURL(for: account.id)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbURL.path + suffix)
        }
        let safeId = OpenDrivePaths.sanitizeAccountId(account.id)
        let metaURL = OpenDrivePaths.appSupportRootURL.appendingPathComponent("\(safeId)-\(OpenDrivePaths.metaFileName)")
        try? FileManager.default.removeItem(at: metaURL)

        saveAccounts()
        await refreshUnlockedVaultStates()
        statusBanner = "Removed \(account.displayName)"
    }

    public func renameAccount(_ account: CloudAccount, to rawName: String) async {
        let cleaned = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !cleaned.isEmpty, cleaned != account.displayName,
              let idx = accounts.firstIndex(where: { $0.id == account.id }) else {
            return
        }
        var updated = accounts[idx]
        updated.displayName = cleaned
        accounts[idx] = updated

        if let store = try? MetadataStore(databaseURL: OpenDrivePaths.databaseURL(for: updated.id)) {
            try? await store.upsertAccount(updated)
        }
        saveAccounts()
        mountManager.signalFileProviderRefresh()
        statusBanner = "Renamed account to \(cleaned)"
    }

    public func renameMountedDrive(to rawName: String) async {
        let sanitized = OpenDrivePaths.sanitizeDriveName(rawName)
        guard !sanitized.isEmpty, sanitized != mountedDriveName else {
            return
        }
        if isSeedMode {
            mountedDriveName = sanitized
            statusBanner = "Mounted drive renamed to \(sanitized)"
            return
        }
        SharedSettings.shared.mountedDriveName = sanitized
        mountedDriveName = sanitized
        await mountManager.remountForRenamedDrive()
        statusBanner = "Mounted drive renamed to \(sanitized)"
    }

    public func refreshStorageQuotas() async {
        guard !isSeedMode else { return }
        let trimmedClientId = googleClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = googleClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = trimmedSecret.isEmpty ? nil : trimmedSecret

        for account in accounts {
            let client = GoogleDriveClient(accountId: account.id, clientId: trimmedClientId, clientSecret: secret)
            if let quota = try? await client.fetchStorageQuota() {
                storageQuotasByAccountId[account.id] = quota
            }
        }
    }

    public func setWholeDriveMode(_ enabled: Bool, for account: CloudAccount) async {
        guard !isSeedMode, !switchingScopeAccountIds.contains(account.id) else { return }
        guard account.wholeDrive != enabled || (enabled && (account.rootId == nil || account.rootId == "root")) else {
            return
        }

        switchingScopeAccountIds.insert(account.id)
        defer { switchingScopeAccountIds.remove(account.id) }

        let trimmedClientId = googleClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = googleClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = trimmedSecret.isEmpty ? nil : trimmedSecret
        let client = GoogleDriveClient(accountId: account.id, clientId: trimmedClientId, clientSecret: secret)

        do {
            let workspace = try await client.ensureWorkspace(wholeDrive: enabled)
            guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }

            var updated = accounts[idx]
            updated.wholeDrive = enabled
            updated.rootId = workspace.rootId
            updated.trashId = workspace.trashId
            updated.changesPageToken = workspace.startPageToken
            accounts[idx] = updated

            if let store = try? MetadataStore(databaseURL: OpenDrivePaths.databaseURL(for: account.id)) {
                try? await store.upsertAccount(updated)
                if let cache = try? ChunkCache(maxBytes: SharedSettings.shared.maxCacheBytes) {
                    let mkData = try? await KeychainStore.shared.loadMasterKey(for: account.id)
                    let masterKey = mkData.map { SymmetricKey(data: $0) }
                    let syncer = SyncEngine(accountId: account.id, store: store, client: client, cache: cache)
                    _ = try? await syncer.hydrateFolderIfNeeded(
                        folderId: workspace.rootId,
                        force: true,
                        masterKey: masterKey
                    )
                }
            }

            saveAccounts()
            mountManager.signalFileProviderRefresh()
            await performPaletteSearch()
            await refreshPinnedItems()
            await refreshRecentFolders()
            let scopeLabel = enabled ? "Whole Google Drive" : "Open Drive Folder"
            statusBanner = "Switched \(updated.displayName) to \(scopeLabel)"
        } catch {
            statusBanner = "Could not switch Drive scope: \(error.localizedDescription)"
        }
    }

    private func resolveCanonicalWholeDriveRootsIfNeeded() async {
        guard !isSeedMode else { return }
        let trimmedClientId = googleClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = googleClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = trimmedSecret.isEmpty ? nil : trimmedSecret

        var changed = false
        for idx in accounts.indices {
            var acc = accounts[idx]
            guard acc.wholeDrive && (acc.rootId == nil || acc.rootId == "root") else { continue }
            let client = GoogleDriveClient(accountId: acc.id, clientId: trimmedClientId, clientSecret: secret)
            if let canonical = try? await client.resolveRootFolderId(), canonical != "root" {
                acc.rootId = canonical
                accounts[idx] = acc
                if let store = try? MetadataStore(databaseURL: OpenDrivePaths.databaseURL(for: acc.id)) {
                    try? await store.upsertAccount(acc)
                }
                changed = true
            }
        }
        if changed {
            saveAccounts()
        }
    }

    public func unlockVault(for account: CloudAccount, secretInput: String) async -> Bool {
        let safeId = OpenDrivePaths.sanitizeAccountId(account.id)
        let metaURL = OpenDrivePaths.appSupportRootURL.appendingPathComponent("\(safeId)-\(OpenDrivePaths.metaFileName)")
        var resolvedBundle: KeyBundle?
        if let data = try? Data(contentsOf: metaURL),
           let decoded = try? JSONDecoder().decode(KeyBundle.self, from: data) {
            resolvedBundle = decoded
        } else {
            let client = GoogleDriveClient(
                accountId: account.id,
                clientId: googleClientId,
                clientSecret: googleClientSecret.isEmpty ? nil : googleClientSecret
            )
            let remoteRootId = account.rootId ?? AppConstants.defaultRootId
            if let remoteMeta = try? await client.fetchKeyBundle(rootId: remoteRootId) {
                resolvedBundle = remoteMeta.bundle
                if let bundleData = try? JSONEncoder().encode(remoteMeta.bundle) {
                    try? OpenDrivePaths.writePrivateFile(bundleData, to: metaURL)
                }
            }
        }

        guard let bundle = resolvedBundle else {
            statusBanner = "Missing .od-meta bundle (local and remote) for \(account.displayName)"
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
        guard !isSeedMode else {
            let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.isEmpty {
                searchResults = pinnedItems
            } else {
                searchResults = pinnedItems.filter { $0.item.shownAs.lowercased().contains(trimmed) }
            }
            return
        }
        var combined: [PaletteSearchHit] = []
        for account in accounts {
            if let store = try? MetadataStore(databaseURL: OpenDrivePaths.databaseURL(for: account.id)),
               let hits = try? await store.searchItems(query: searchQuery, limit: 30) {
                for hit in hits {
                    let components = (try? await store.resolveRelativePathComponents(for: hit, rootId: account.rootId))
                        ?? [hit.shownAs.isEmpty ? hit.name : hit.shownAs]
                    combined.append(
                        PaletteSearchHit(
                            account: account,
                            item: hit,
                            relativePathComponents: components
                        )
                    )
                }
            }
        }
        searchResults = combined
    }

    public func refreshPinnedItems() async {
        guard !isSeedMode else { return }
        var combined: [PaletteSearchHit] = []
        for account in accounts {
            if let store = try? MetadataStore(databaseURL: OpenDrivePaths.databaseURL(for: account.id)),
               let pinned = try? await store.fetchPinnedItems() {
                for hit in pinned {
                    let components = (try? await store.resolveRelativePathComponents(for: hit, rootId: account.rootId))
                        ?? [hit.shownAs.isEmpty ? hit.name : hit.shownAs]
                    combined.append(
                        PaletteSearchHit(
                            account: account,
                            item: hit,
                            relativePathComponents: components
                        )
                    )
                }
            }
        }
        pinnedItems = combined
    }

    public func togglePin(item: DriveItem, in account: CloudAccount) async {
        guard !isSeedMode else {
            pinnedItems.removeAll { $0.item.driveId == item.driveId && $0.account.id == account.id }
            return
        }
        guard let store = try? MetadataStore(databaseURL: OpenDrivePaths.databaseURL(for: account.id)) else { return }
        let newPinned = !item.pinned
        try? await store.setPinned(driveId: item.driveId, pinned: newPinned)
        if newPinned {
            DarwinNotifier.shared.post(.signal)
        }
        await performPaletteSearch()
        await refreshPinnedItems()
    }

    public func localVFSURL(for hit: PaletteSearchHit) -> URL {
        let baseURL = accounts.count > 1
            ? mountManager.activeMountURL.appendingPathComponent(
                MetadataStore.sanitizeDisplayName(hit.account.displayName),
                isDirectory: true
            )
            : mountManager.activeMountURL
        var url = baseURL
        for (idx, component) in hit.relativePathComponents.enumerated() {
            let safeComp = MetadataStore.sanitizeDisplayName(component)
            let isLast = (idx == hit.relativePathComponents.count - 1)
            url.appendPathComponent(safeComp, isDirectory: isLast ? hit.item.isFolder : true)
        }
        let baseStd = baseURL.standardizedFileURL.path
        let finalStd = url.standardizedFileURL.path
        if finalStd == baseStd || finalStd.hasPrefix(baseStd + "/") {
            return url
        }
        return baseURL
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
        var byAccount: [String: [RecentFolderRecord]] = [:]
        for account in accounts {
            if let store = try? MetadataStore(databaseURL: OpenDrivePaths.databaseURL(for: account.id)),
               let recent = try? await store.listRecentFolders(limit: 8) {
                all.append(contentsOf: recent)
                byAccount[account.id] = recent
            }
        }
        recentFolders = all
        recentFoldersByAccount = byAccount
    }

    public func recentFolders(for accountId: String?) -> [RecentFolderRecord] {
        guard let targetId = accountId ?? accounts.first?.id else { return [] }
        return recentFoldersByAccount[targetId] ?? []
    }

    public func enqueueDroppedFiles(
        urls: [URL],
        targetAccountId: String? = nil,
        targetFolderId: String?
    ) async {
        guard let targetAccount = targetAccountId.flatMap({ id in accounts.first(where: { $0.id == id }) }) ?? accounts.first,
              let store = try? MetadataStore(databaseURL: OpenDrivePaths.databaseURL(for: targetAccount.id)) else {
            statusBanner = "Connect a Google Drive account before dropping files"
            return
        }
        let parentId = targetFolderId ?? targetAccount.rootId ?? AppConstants.defaultRootId
        let client = GoogleDriveClient(
            accountId: targetAccount.id,
            clientId: googleClientId,
            clientSecret: googleClientSecret.isEmpty ? nil : googleClientSecret
        )
        let uploader = UploadEngine(store: store, client: client)

        try? OpenDrivePaths.createPrivateDirectory(at: OpenDrivePaths.scratchCacheURL)
        var queuedCount = 0
        for fileURL in urls where fileURL.isFileURL {
            let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard vals?.isRegularFile == true else { continue }
            let safeName = MetadataStore.sanitizeDisplayName(fileURL.lastPathComponent)
            let stagedURL = OpenDrivePaths.scratchCacheURL.appendingPathComponent("\(UUID().uuidString)-\(safeName)")
            do {
                try FileManager.default.copyItem(at: fileURL, to: stagedURL)
                OpenDrivePaths.setPrivateFilePermissions(at: stagedURL)
                _ = try await uploader.enqueueUpload(
                    localURL: stagedURL,
                    parentId: parentId,
                    targetDriveId: nil,
                    name: safeName,
                    encrypt: targetAccount.encryptionEnabled
                )
                queuedCount += 1
            } catch {
                try? FileManager.default.removeItem(at: stagedURL)
            }
        }
        guard queuedCount > 0 else { return }
        await refreshPendingUploads()
        statusBanner = "Queued \(queuedCount) file(s) for \(targetAccount.displayName)"
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

    public func retryUpload(_ record: UploadRecord) async {
        for account in accounts {
            if let store = try? MetadataStore(databaseURL: OpenDrivePaths.databaseURL(for: account.id)) {
                try? await store.retryUpload(id: record.id)
            }
        }
        DarwinNotifier.shared.post(.signal)
        await refreshPendingUploads()
    }

    public func clearChunkCache() {
        DarwinNotifier.shared.post(.clearCache)
        statusBanner = "Purged local chunk cache"
    }

    public func refreshLaunchAtLoginStatus() {
        guard !isSeedMode else { return }
        let status = SMAppService.mainApp.status
        launchAtLogin = (status == .enabled || status == .requiresApproval)
        launchAtLoginRequiresApproval = (status == .requiresApproval)
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        if isSeedMode {
            launchAtLogin = enabled
            return
        }
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLoginStatus()
    }

    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

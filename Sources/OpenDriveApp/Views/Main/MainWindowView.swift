import AppKit
import OpenDriveCore
import SwiftUI
import UniformTypeIdentifiers

/// Native macOS main window with a NavigationSplitView sidebar covering Overview,
/// Accounts, Uploads, and Offline Files.
struct MainWindowView: View {
    @ObservedObject var viewModel: OpenDriveAppViewModel
    @Environment(\.openSettings) private var openSettings

    @State private var selectedAccountId: String? = nil
    @State private var selectedRecentFolderId: String? = nil
    @State private var unlockInputs: [String: String] = [:]

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $viewModel.selectedSidebarItem) { section in
                rowLabel(for: section)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ODTheme.canvasBg)
                .navigationTitle(viewModel.selectedSidebarItem.title)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            viewModel.paletteController?.togglePalette()
                        } label: {
                            Label("Search", systemImage: "magnifyingglass")
                        }
                        .help("Global Search Across All Drives (⌃⌥F)")

                        Button {
                            if !viewModel.isSeedMode {
                                DarwinNotifier.shared.post(.signal)
                                viewModel.mountManager.signalFileProviderRefresh()
                                Task { await viewModel.refreshStorageQuotas() }
                            }
                        } label: {
                            Label("Refresh Sync", systemImage: "arrow.clockwise")
                        }
                        .help("Refresh Sync With Google Drive (⌘R)")

                        Button {
                            NSWorkspace.shared.open(viewModel.mountManager.activeMountURL)
                        } label: {
                            Label("Open in Finder", systemImage: "folder")
                        }
                        .help("Reveal Open Drive in Finder (⌘O)")

                        Button {
                            OpenDriveAppDelegate.shared?.prepareForWindowPresentation()
                            openSettings()
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .help("Open Settings (⌘,)")
                    }
                }
        }
        .noInitialFocus()
    }

    // MARK: - Sidebar Row

    @ViewBuilder
    private func rowLabel(for section: SidebarSection) -> some View {
        let count = badgeCount(for: section)
        if count > 0 {
            Label(section.title, systemImage: section.symbolName)
                .badge(count)
        } else {
            Label(section.title, systemImage: section.symbolName)
        }
    }

    private func badgeCount(for section: SidebarSection) -> Int {
        switch section {
        case .overview: return 0
        case .accounts: return viewModel.accounts.count
        case .uploads: return viewModel.pendingUploads.count
        case .offline: return viewModel.pinnedItems.count
        }
    }

    // MARK: - Detail Pages

    @ViewBuilder
    private var detailContent: some View {
        switch viewModel.selectedSidebarItem {
        case .overview:
            overviewPage
        case .accounts:
            accountsPage
        case .uploads:
            uploadsPage
        case .offline:
            offlineFilesPage
        }
    }

    private var overviewPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                heroDriveCard

                factsStrip

                if !viewModel.accounts.isEmpty {
                    storageSection
                }

                statusActivitySection

                VStack(alignment: .leading, spacing: 8) {
                    ODSectionHeader(
                        title: "Quick Upload",
                        detail: "Non-blocking 4 MiB resumable PUT"
                    )
                    ODDropZoneCard(
                        viewModel: viewModel,
                        selectedAccountId: $selectedAccountId,
                        selectedRecentFolderId: $selectedRecentFolderId
                    )
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var heroDriveCard: some View {
        ODCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    ODStatusCircle(
                        size: 40,
                        systemImage: "externaldrive.fill.badge.icloud",
                        background: ODTheme.ink,
                        foreground: ODTheme.onInk
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(viewModel.mountedDriveName)
                                .font(.title3.weight(.semibold))

                            ODBadgePill(
                                text: viewModel.mountManager.isMounted ? "Mounted" : "Not Mounted",
                                dotColor: viewModel.mountManager.isMounted ? ODTheme.saving : .secondary,
                                foreground: viewModel.mountManager.isMounted ? ODTheme.saving : .secondary,
                                background: viewModel.mountManager.isMounted ? ODTheme.savingBg : ODTheme.softFill
                            )
                        }

                        if !viewModel.mountManager.lastMountMessage.isEmpty {
                            Text(viewModel.mountManager.lastMountMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if viewModel.mountManager.isMounted {
                        ODBadgePill(
                            text: "Zero bytes on disk",
                            systemImage: "checkmark.circle.fill",
                            foreground: ODTheme.saving,
                            background: ODTheme.savingBg
                        )
                    }
                }

                Rectangle()
                    .fill(ODTheme.hairline)
                    .frame(height: 0.5)

                HStack(spacing: 10) {
                    Text("Mount Path")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(viewModel.mountManager.activeMountURL.path.abbreviatingHomeDirectory)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Button {
                        guard !viewModel.isSeedMode else { return }
                        NSWorkspace.shared.open(viewModel.mountManager.activeMountURL)
                    } label: {
                        Label("Open in Finder", systemImage: "folder")
                    }
                    .buttonStyle(ODPillButtonStyle(variant: .primary))

                    MountedDriveRenameButton(viewModel: viewModel, usePillStyle: true)

                    Button("Refresh Sync") {
                        guard !viewModel.isSeedMode else { return }
                        DarwinNotifier.shared.post(.signal)
                        viewModel.mountManager.signalFileProviderRefresh()
                        Task { await viewModel.refreshStorageQuotas() }
                    }
                    .buttonStyle(ODPillButtonStyle(variant: .secondary))

                    let mountButtonTitle = viewModel.mountManager.isMountInProgress
                        ? "Mounting…"
                        : (viewModel.mountManager.isMounted ? "Unmount Volume" : "Mount Volume")
                    Button(mountButtonTitle) {
                        guard !viewModel.isSeedMode else { return }
                        if viewModel.mountManager.isMounted {
                            viewModel.mountManager.unmountFilesystem()
                        } else {
                            viewModel.mountManager.mountFilesystem()
                        }
                    }
                    .buttonStyle(ODPillButtonStyle(variant: .secondary))
                    .disabled(viewModel.mountManager.isMountInProgress)

                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var factsStrip: some View {
        HStack(spacing: 12) {
            ODCard(padding: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("0 bytes")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text("used on your Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ODCard(padding: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(shortCloudAvailableValue)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text("free in Google Drive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ODCard(padding: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Int(viewModel.maxCacheGiB)) GiB")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text("4 MiB streaming cache")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var shortCloudAvailableValue: String {
        if let available = viewModel.aggregatedStorageQuota?.availableBytes {
            return available.formattedFileSize
        }
        return "—"
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ODSectionHeader(
                title: "Google Drive Storage",
                detail: "\(viewModel.accounts.count) \(viewModel.accounts.count == 1 ? "drive" : "drives")"
            )

            ODCard(padding: 16) {
                if let quota = viewModel.aggregatedStorageQuota {
                    VStack(alignment: .leading, spacing: 12) {
                        ODSegmentedQuotaBar(
                            quota: quota,
                            segments: storageSegments,
                            showZeroLocalBadge: true
                        )

                        if viewModel.accounts.count > 1 {
                            Rectangle()
                                .fill(ODTheme.hairline)
                                .frame(height: 0.5)

                            VStack(spacing: 8) {
                                ForEach(viewModel.accounts) { account in
                                    let isUnlocked = !account.encryptionEnabled || viewModel.unlockedAccountIds.contains(account.id)
                                    HStack(spacing: 10) {
                                        ODStatusCircle(
                                            size: 24,
                                            systemImage: account.encryptionEnabled
                                                ? (isUnlocked ? "lock.open.fill" : "lock.fill")
                                                : "cloud.fill",
                                            background: ODTheme.softFill,
                                            foreground: ODTheme.ink
                                        )
                                        Text(account.displayName)
                                            .font(.subheadline.weight(.medium))
                                        ODBadgePill(
                                            text: account.encryptionEnabled ? "ODE1 Vault" : (account.wholeDrive ? "Whole Drive" : "Folder"),
                                            foreground: .secondary,
                                            background: ODTheme.softFill
                                        )
                                        Spacer()
                                        if let accountQuota = viewModel.storageQuotasByAccountId[account.id] {
                                            Text(accountQuota.compactAvailableSummary)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .monospacedDigit()
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading Google Drive storage…")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh") {
                            guard !viewModel.isSeedMode else { return }
                            Task { await viewModel.refreshStorageQuotas() }
                        }
                        .buttonStyle(ODPillButtonStyle(variant: .secondary, compact: true))
                    }
                }
            }
        }
    }

    private var storageSegments: [ODStorageSegment] {
        viewModel.accounts.compactMap { account in
            guard let q = viewModel.storageQuotasByAccountId[account.id] else { return nil }
            return ODStorageSegment(id: account.id, name: account.displayName, usedBytes: q.usedBytes)
        }
    }

    private var statusActivitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ODSectionHeader(title: "Status & Activity")

            ODCard(padding: 0) {
                VStack(spacing: 0) {
                    HStack {
                        Label("Network", systemImage: networkStatusSymbol)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                        ODBadgePill(
                            text: networkStatusTitle,
                            dotColor: networkStatusColor,
                            foreground: networkStatusColor,
                            background: networkBadgeBackground
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    Rectangle().fill(ODTheme.hairline).frame(height: 0.5)

                    activityNavRow(
                        title: "Connected Accounts",
                        symbol: "person.2.fill",
                        value: "\(viewModel.accounts.count)"
                    ) {
                        viewModel.selectedSidebarItem = .accounts
                    }

                    Rectangle().fill(ODTheme.hairline).frame(height: 0.5)

                    activityNavRow(
                        title: "Active Uploads",
                        symbol: "arrow.up.circle.fill",
                        value: "\(viewModel.pendingUploads.count)"
                    ) {
                        viewModel.selectedSidebarItem = .uploads
                    }

                    Rectangle().fill(ODTheme.hairline).frame(height: 0.5)

                    activityNavRow(
                        title: "Pinned Offline Files",
                        symbol: "pin.fill",
                        value: "\(viewModel.pinnedItems.count)"
                    ) {
                        viewModel.selectedSidebarItem = .offline
                    }

                    if viewModel.accounts.isEmpty {
                        Rectangle().fill(ODTheme.hairline).frame(height: 0.5)
                        HStack {
                            Text("No Google Drive accounts connected yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Connect Google Drive…") {
                                viewModel.selectedSettingsTab = .accounts
                                OpenDriveAppDelegate.shared?.prepareForWindowPresentation()
                                openSettings()
                            }
                            .buttonStyle(ODPillButtonStyle(variant: .primary, compact: true))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    private func activityNavRow(
        title: String,
        symbol: String,
        value: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var accountsPage: some View {
        if viewModel.accounts.isEmpty {
            ContentUnavailableView {
                Label("No Google Drive Accounts", systemImage: "person.2.circle")
            } description: {
                Text("Connect a Google Drive account in Settings to mount and browse your files in Finder.")
            } actions: {
                Button("Open Accounts Settings…") {
                    viewModel.selectedSettingsTab = .accounts
                    OpenDriveAppDelegate.shared?.prepareForWindowPresentation()
                    openSettings()
                }
                .buttonStyle(ODPillButtonStyle(variant: .primary))
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ODSectionHeader(
                        title: "Connected Accounts (\(viewModel.accounts.count))",
                        detail: "OAuth 2.0 PKCE + ODE1 Vault"
                    )

                    ForEach(viewModel.accounts) { account in
                        let isUnlocked = !account.encryptionEnabled || viewModel.unlockedAccountIds.contains(account.id)
                        ODCard(padding: 16) {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 12) {
                                    ODStatusCircle(
                                        size: 34,
                                        systemImage: account.encryptionEnabled
                                            ? (isUnlocked ? "lock.open.fill" : "lock.fill")
                                            : "cloud.fill",
                                        background: account.encryptionEnabled && !isUnlocked ? ODTheme.warningBg : ODTheme.softFill,
                                        foreground: account.encryptionEnabled && !isUnlocked ? ODTheme.warning : ODTheme.ink
                                    )

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(account.displayName)
                                                .font(.headline)
                                            if account.encryptionEnabled {
                                                ODBadgePill(
                                                    text: isUnlocked ? "ODE1 Unlocked" : "ODE1 Locked",
                                                    foreground: isUnlocked ? ODTheme.saving : ODTheme.warning,
                                                    background: isUnlocked ? ODTheme.savingBg : ODTheme.warningBg
                                                )
                                            }
                                        }
                                        Text(accountSubtitle(for: account, isUnlocked: isUnlocked))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    AccountScopePicker(account: account, viewModel: viewModel)

                                    AccountRenameButton(account: account, viewModel: viewModel, usePillStyle: true)

                                    Button("Remove", role: .destructive) {
                                        guard !viewModel.isSeedMode else { return }
                                        Task { await viewModel.removeAccount(account) }
                                    }
                                    .buttonStyle(ODPillButtonStyle(variant: .destructive, compact: true))
                                }

                                if let accountQuota = viewModel.storageQuotasByAccountId[account.id] {
                                    Rectangle().fill(ODTheme.hairline).frame(height: 0.5)
                                    ODSegmentedQuotaBar(quota: accountQuota, compact: true)
                                }

                                if account.encryptionEnabled && !isUnlocked {
                                    HStack(spacing: 8) {
                                        SecureField("Passphrase or 24-word recovery key", text: bindingForUnlockInput(account.id))
                                            .textFieldStyle(.roundedBorder)
                                        Button("Unlock Vault") {
                                            let secret = unlockInputs[account.id] ?? ""
                                            Task {
                                                _ = await viewModel.unlockVault(for: account, secretInput: secret)
                                                unlockInputs[account.id] = ""
                                            }
                                        }
                                        .buttonStyle(ODPillButtonStyle(variant: .primary, compact: true))
                                    }
                                }
                            }
                        }
                    }

                    ODSectionHeader(title: "Zero-Knowledge Vault Specification")
                    ODVaultSpecCard()

                    ODCard(padding: 14) {
                        HStack {
                            Text("Add an account, sign in with Google PKCE, or export a 24-word recovery key PDF.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Open Accounts Settings…") {
                                viewModel.selectedSettingsTab = .accounts
                                OpenDriveAppDelegate.shared?.prepareForWindowPresentation()
                                openSettings()
                            }
                            .buttonStyle(ODPillButtonStyle(variant: .secondary, compact: true))
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var uploadsPage: some View {
        if viewModel.pendingUploads.isEmpty {
            VStack(spacing: 20) {
                ContentUnavailableView {
                    Label("No Active Uploads", systemImage: "arrow.up.circle")
                } description: {
                    Text("Drag files below, save directly inside Open Drive in Finder, or select files in Finder and press ⌘⇧C.")
                }

                ODDropZoneCard(
                    viewModel: viewModel,
                    selectedAccountId: $selectedAccountId,
                    selectedRecentFolderId: $selectedRecentFolderId
                )
                .frame(maxWidth: 460)
                .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    uploadSummaryCard

                    VStack(alignment: .leading, spacing: 8) {
                        ODSectionHeader(
                            title: "Upload Queue (\(viewModel.pendingUploads.count))",
                            detail: "4 MiB resumable HTTP PUT"
                        )

                        ODCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(viewModel.pendingUploads.enumerated()), id: \.element.id) { idx, upload in
                                    if idx > 0 {
                                        Rectangle().fill(ODTheme.hairline).frame(height: 0.5)
                                    }
                                    uploadQueueRow(upload)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ODSectionHeader(title: "Queue More Files")
                        ODDropZoneCard(
                            viewModel: viewModel,
                            selectedAccountId: $selectedAccountId,
                            selectedRecentFolderId: $selectedRecentFolderId
                        )
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var uploadSummaryCard: some View {
        let totalBytes = viewModel.pendingUploads.reduce(Int64(0)) { $0 + max(1, $1.size) }
        let uploadedBytes = viewModel.pendingUploads.reduce(Int64(0)) { $0 + min($1.offset, $1.size) }
        let overallProgress = totalBytes > 0 ? Double(uploadedBytes) / Double(totalBytes) : 0

        return ODCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ODStatusCircle(size: 34, systemImage: "arrow.up")

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Uploading \(viewModel.pendingUploads.count) \(viewModel.pendingUploads.count == 1 ? "file" : "files")…")
                            .font(.headline)
                        Text("\(uploadedBytes.formattedFileSize) of \(totalBytes.formattedFileSize)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Spacer()

                    ODBadgePill(
                        text: viewModel.pauseOnMetered ? "Hotspot Guard On" : "Hotspot Guard Off",
                        dotColor: viewModel.pauseOnMetered ? ODTheme.saving : .secondary,
                        foreground: viewModel.pauseOnMetered ? ODTheme.saving : .secondary,
                        background: viewModel.pauseOnMetered ? ODTheme.savingBg : ODTheme.softFill
                    )
                }

                ODProgressTrack(fraction: overallProgress, height: 5)
            }
        }
    }

    private func uploadQueueRow(_ upload: UploadRecord) -> some View {
        let progress = upload.size > 0 ? Double(upload.offset) / Double(upload.size) : 0
        return HStack(spacing: 12) {
            ODStatusCircle(
                size: 28,
                systemImage: uploadSymbol(for: upload),
                background: uploadBadgeBackground(for: upload),
                foreground: uploadColor(for: upload)
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(upload.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(upload.state.rawValue.capitalized) · \(upload.offset.formattedFileSize) / \(upload.size.formattedFileSize)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                ODProgressTrack(fraction: progress, tint: uploadColor(for: upload), height: 3.5)

                if let err = upload.lastError, !err.isEmpty {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(upload.state == .paused ? ODTheme.warning : ODTheme.danger)
                        .lineLimit(2)
                }
            }

            if upload.state == .failed || upload.state == .paused {
                Button("Retry") {
                    guard !viewModel.isSeedMode else { return }
                    Task { await viewModel.retryUpload(upload) }
                }
                .buttonStyle(ODPillButtonStyle(variant: .secondary, compact: true))
            }

            Button("Cancel") {
                guard !viewModel.isSeedMode else { return }
                Task { await viewModel.cancelUpload(upload) }
            }
            .buttonStyle(ODPillButtonStyle(variant: .secondary, compact: true))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var offlineFilesPage: some View {
        if viewModel.pinnedItems.isEmpty {
            ContentUnavailableView {
                Label("No Pinned Files", systemImage: "pin.circle")
            } description: {
                Text("Pin files in Global Search (⌃⌥F) or the menu bar to keep their chunks downloaded and exempt from cache eviction.")
            } actions: {
                Button("Open Global Search (⌃⌥F)") {
                    viewModel.paletteController?.showPalette()
                }
                .buttonStyle(ODPillButtonStyle(variant: .primary))
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ODCard(padding: 16) {
                        HStack(spacing: 12) {
                            ODStatusCircle(size: 34, systemImage: "pin.fill")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Pinned Offline Files (\(viewModel.pinnedItems.count))")
                                    .font(.headline)
                                Text("Exempt from LRU disk cache eviction · Available without Wi-Fi")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Global Search (⌃⌥F)") {
                                viewModel.paletteController?.showPalette()
                            }
                            .buttonStyle(ODPillButtonStyle(variant: .secondary, compact: true))
                        }
                    }

                    ODCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(viewModel.pinnedItems.enumerated()), id: \.element.id) { idx, hit in
                                if idx > 0 {
                                    Rectangle().fill(ODTheme.hairline).frame(height: 0.5)
                                }
                                HStack(spacing: 12) {
                                    ODStatusCircle(
                                        size: 28,
                                        systemImage: hit.item.isEncrypted ? "lock.doc.fill" : "doc.fill",
                                        background: hit.item.isEncrypted ? ODTheme.warningBg : ODTheme.softFill,
                                        foreground: hit.item.isEncrypted ? ODTheme.warning : ODTheme.ink
                                    )

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(hit.item.shownAs)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(1)
                                        Text("\(hit.account.displayName)\(hit.parentFolderBreadcrumb.isEmpty ? "" : " / \(hit.parentFolderBreadcrumb)") • \(hit.item.size.formattedFileSize)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    ODBadgePill(
                                        text: "Pinned",
                                        foreground: ODTheme.saving,
                                        background: ODTheme.savingBg
                                    )

                                    Button("Reveal") {
                                        guard !viewModel.isSeedMode else { return }
                                        let url = viewModel.localVFSURL(for: hit)
                                        NSWorkspace.shared.activateFileViewerSelecting([url])
                                    }
                                    .buttonStyle(ODPillButtonStyle(variant: .secondary, compact: true))

                                    Button("Open") {
                                        guard !viewModel.isSeedMode else { return }
                                        let url = viewModel.localVFSURL(for: hit)
                                        NSWorkspace.shared.open(url)
                                    }
                                    .buttonStyle(ODPillButtonStyle(variant: .primary, compact: true))

                                    Button("Unpin") {
                                        Task { await viewModel.togglePin(item: hit.item, in: hit.account) }
                                    }
                                    .buttonStyle(ODPillButtonStyle(variant: .secondary, compact: true))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 11)
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Helpers

    private func bindingForUnlockInput(_ accountId: String) -> Binding<String> {
        Binding(
            get: { unlockInputs[accountId] ?? "" },
            set: { unlockInputs[accountId] = $0 }
        )
    }

    private func accountSubtitle(for account: CloudAccount, isUnlocked: Bool) -> String {
        var parts: [String] = []
        if let email = account.email, !email.isEmpty {
            parts.append(email)
        }
        parts.append(account.wholeDrive ? "Whole Drive" : "Open Drive Folder")
        if account.encryptionEnabled {
            parts.append(isUnlocked ? "Vault Unlocked" : "Vault Locked")
        }
        return parts.joined(separator: " • ")
    }

    private func uploadSymbol(for upload: UploadRecord) -> String {
        switch upload.state {
        case .uploading, .committing: return "arrow.up"
        case .queued: return "clock"
        case .paused: return "pause"
        case .failed: return "exclamationmark.triangle"
        case .done: return "checkmark"
        }
    }

    private func uploadColor(for upload: UploadRecord) -> Color {
        switch upload.state {
        case .uploading, .committing: return ODTheme.ink
        case .queued: return .secondary
        case .paused: return ODTheme.warning
        case .failed: return ODTheme.danger
        case .done: return ODTheme.saving
        }
    }

    private func uploadBadgeBackground(for upload: UploadRecord) -> Color {
        switch upload.state {
        case .uploading, .committing, .queued: return ODTheme.softFill
        case .paused: return ODTheme.warningBg
        case .failed: return ODTheme.dangerBg
        case .done: return ODTheme.savingBg
        }
    }

    private var networkStatusTitle: String {
        if viewModel.isNetworkOffline { return "Offline" }
        if viewModel.isNetworkMetered { return "Personal Hotspot (Metered)" }
        return "Online"
    }

    private var networkStatusSymbol: String {
        if viewModel.isNetworkOffline { return "wifi.slash" }
        if viewModel.isNetworkMetered { return "personalhotspot" }
        return "wifi"
    }

    private var networkStatusColor: Color {
        if viewModel.isNetworkOffline { return ODTheme.danger }
        if viewModel.isNetworkMetered { return ODTheme.warning }
        return ODTheme.saving
    }

    private var networkBadgeBackground: Color {
        if viewModel.isNetworkOffline { return ODTheme.dangerBg }
        if viewModel.isNetworkMetered { return ODTheme.warningBg }
        return ODTheme.savingBg
    }
}

struct StorageQuotaBar: View {
    let quota: CloudStorageQuota
    var compact: Bool = false

    var body: some View {
        ODSegmentedQuotaBar(quota: quota, compact: compact)
    }
}

struct AccountScopePicker: View {
    let account: CloudAccount
    @ObservedObject var viewModel: OpenDriveAppViewModel

    var body: some View {
        HStack(spacing: 6) {
            if viewModel.switchingScopeAccountIds.contains(account.id) {
                ProgressView()
                    .controlSize(.small)
            }
            Picker("Drive Scope", selection: Binding(
                get: { account.wholeDrive },
                set: { newValue in
                    guard !viewModel.isSeedMode else { return }
                    Task { await viewModel.setWholeDriveMode(newValue, for: account) }
                }
            )) {
                Text("Whole Google Drive").tag(true)
                Text("Open Drive Folder").tag(false)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .disabled(viewModel.isSeedMode || viewModel.switchingScopeAccountIds.contains(account.id))
        }
    }
}

struct RenamePromptButton: View {
    let buttonTitle: String
    let alertTitle: String
    let fieldPlaceholder: String
    let initialValue: String
    let message: String
    var disabled: Bool = false
    var usePillStyle: Bool = false
    var compactPill: Bool = false
    let onSave: (String) async -> Void

    @State private var isPresenting = false
    @State private var draft = ""

    var body: some View {
        Group {
            if usePillStyle {
                Button(buttonTitle) {
                    draft = initialValue
                    isPresenting = true
                }
                .buttonStyle(ODPillButtonStyle(variant: .secondary, compact: compactPill))
            } else {
                Button(buttonTitle) {
                    draft = initialValue
                    isPresenting = true
                }
                .controlSize(.small)
            }
        }
        .disabled(disabled)
        .alert(alertTitle, isPresented: $isPresenting) {
            TextField(fieldPlaceholder, text: $draft)
            Button("Save") {
                let targetName = draft
                Task { await onSave(targetName) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

struct AccountRenameButton: View {
    let account: CloudAccount
    @ObservedObject var viewModel: OpenDriveAppViewModel
    var usePillStyle: Bool = false

    var body: some View {
        RenamePromptButton(
            buttonTitle: "Rename…",
            alertTitle: "Rename Account",
            fieldPlaceholder: "Folder Display Name",
            initialValue: account.displayName,
            message: "Choose the folder display name used in Open Drive for \(account.email ?? account.displayName).",
            disabled: viewModel.isSeedMode,
            usePillStyle: usePillStyle,
            compactPill: true
        ) { targetName in
            await viewModel.renameAccount(account, to: targetName)
        }
    }
}

struct MountedDriveRenameButton: View {
    @ObservedObject var viewModel: OpenDriveAppViewModel
    var usePillStyle: Bool = false
    var compactPill: Bool = false

    var body: some View {
        RenamePromptButton(
            buttonTitle: "Rename Drive…",
            alertTitle: "Rename Mounted Drive",
            fieldPlaceholder: "Drive Name",
            initialValue: viewModel.mountedDriveName,
            message: "Choose the name shown in Finder for the mounted Google Drive.",
            disabled: viewModel.mountManager.isMountInProgress,
            usePillStyle: usePillStyle,
            compactPill: compactPill
        ) { targetName in
            await viewModel.renameMountedDrive(to: targetName)
        }
    }
}

extension CloudStorageQuota {
    var compactAvailableSummary: String {
        if let total = totalBytes, let available = availableBytes {
            return "\(available.formattedFileSize) available of \(total.formattedFileSize)"
        }
        return "\(usedBytes.formattedFileSize) used • Unlimited"
    }

    var shortAvailableLabel: String {
        if let available = availableBytes {
            return "\(available.formattedFileSize) free"
        }
        return "\(usedBytes.formattedFileSize) used"
    }
}

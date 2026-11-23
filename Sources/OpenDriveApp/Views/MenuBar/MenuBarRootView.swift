import AppKit
import OpenDriveCore
import SwiftUI

/// Menu-bar popover view modeled after the clean floating macOS panels on the Open Drive site.
struct MenuBarRootView: View {
    @ObservedObject var viewModel: OpenDriveAppViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var selectedAccountId: String? = nil
    @State private var selectedRecentFolderId: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            statusHeader

            searchRow

            if !viewModel.searchResults.isEmpty && !viewModel.searchQuery.isEmpty {
                inlineSearchResults
            }

            ODDropZoneCard(
                viewModel: viewModel,
                selectedAccountId: $selectedAccountId,
                selectedRecentFolderId: $selectedRecentFolderId,
                compact: true
            )

            if !viewModel.pendingUploads.isEmpty {
                Rectangle().fill(ODTheme.hairline).frame(height: 0.5)
                uploadsSection
            }

            Rectangle().fill(ODTheme.hairline).frame(height: 0.5)
            accountsSection

            Rectangle().fill(ODTheme.hairline).frame(height: 0.5)
            VStack(spacing: 1) {
                ODMenuActionRow(title: "Open in Finder", systemImage: "folder", shortcut: "⌘O") {
                    guard !viewModel.isSeedMode else { return }
                    NSWorkspace.shared.open(viewModel.mountManager.activeMountURL)
                }
                ODMenuActionRow(title: "Open Main Window", systemImage: "macwindow") {
                    presentWindow { openWindow(id: "main") }
                }
                ODMenuActionRow(title: "Global Search", systemImage: "magnifyingglass", shortcut: "⌃⌥F") {
                    viewModel.paletteController?.togglePalette()
                }
                ODMenuActionRow(title: "Refresh Sync", systemImage: "arrow.clockwise", shortcut: "⌘R") {
                    guard !viewModel.isSeedMode else { return }
                    DarwinNotifier.shared.post(.signal)
                    viewModel.mountManager.signalFileProviderRefresh()
                    Task { await viewModel.refreshStorageQuotas() }
                }
            }

            Rectangle().fill(ODTheme.hairline).frame(height: 0.5)
            VStack(spacing: 1) {
                ODMenuActionRow(title: "Settings…", systemImage: "gearshape", shortcut: "⌘,") {
                    presentWindow { openSettings() }
                }
                ODMenuActionRow(title: "Clear Local Cache", systemImage: "internaldrive") {
                    guard !viewModel.isSeedMode else { return }
                    viewModel.clearChunkCache()
                }
                ODMenuActionRow(title: "Quit Open Drive", systemImage: "power", shortcut: "⌘Q") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(12)
        .frame(width: 344)
        .onAppear {
            if OpenDriveAppDelegate.shared?.openMainWindowAction == nil {
                OpenDriveAppDelegate.shared?.openMainWindowAction = {
                    openWindow(id: "main")
                }
            }
        }
    }

    // MARK: - Sections

    private var statusHeader: some View {
        let hasUploads = !viewModel.pendingUploads.isEmpty
        let totalBytes = viewModel.pendingUploads.reduce(Int64(0)) { $0 + max(1, $1.size) }
        let uploadedBytes = viewModel.pendingUploads.reduce(Int64(0)) { $0 + min($1.offset, $1.size) }
        let overallProgress = totalBytes > 0 ? Double(uploadedBytes) / Double(totalBytes) : 0

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ODStatusCircle(
                    size: 28,
                    systemImage: hasUploads ? "arrow.up" : "externaldrive.fill.badge.icloud",
                    background: ODTheme.ink,
                    foreground: ODTheme.onInk
                )

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(hasUploads
                             ? "Uploading \(viewModel.pendingUploads.count) \(viewModel.pendingUploads.count == 1 ? "file" : "files")…"
                             : viewModel.mountedDriveName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        if viewModel.isNetworkOffline {
                            ODBadgePill(
                                text: "Offline",
                                foreground: ODTheme.danger,
                                background: ODTheme.dangerBg
                            )
                        } else if viewModel.isNetworkMetered {
                            ODBadgePill(
                                text: "Hotspot",
                                foreground: ODTheme.warning,
                                background: ODTheme.warningBg
                            )
                        }
                    }

                    Text(statusSubtitle(
                        hasUploads: hasUploads,
                        uploadedBytes: uploadedBytes,
                        totalBytes: totalBytes
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .monospacedDigit()
                }

                Spacer(minLength: 4)

                Button(viewModel.mountManager.isMounted ? "Unmount" : "Mount") {
                    guard !viewModel.isSeedMode else { return }
                    if viewModel.mountManager.isMounted {
                        viewModel.mountManager.unmountFilesystem()
                    } else {
                        viewModel.mountManager.mountFilesystem()
                    }
                }
                .buttonStyle(
                    ODPillButtonStyle(
                        variant: viewModel.mountManager.isMounted ? .secondary : .primary,
                        compact: true
                    )
                )
            }

            if hasUploads {
                ODProgressTrack(fraction: overallProgress, height: 3.5)
                    .padding(.leading, 38)
            }
        }
        .padding(.horizontal, 2)
    }

    private func statusSubtitle(hasUploads: Bool, uploadedBytes: Int64, totalBytes: Int64) -> String {
        if hasUploads {
            return "\(uploadedBytes.formattedFileSize) of \(totalBytes.formattedFileSize)"
        }
        if let quota = viewModel.aggregatedStorageQuota, !viewModel.accounts.isEmpty {
            return "\(quota.shortAvailableLabel) · Zero KB local"
        }
        return viewModel.statusBanner
    }

    private var searchRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Search Open Drive…", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .font(.caption)
                .onSubmit {
                    Task { await viewModel.performPaletteSearch() }
                }

            Button {
                viewModel.paletteController?.togglePalette()
            } label: {
                Text("⌃⌥F")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(ODTheme.cardBg))
            }
            .buttonStyle(.plain)
            .help("Open Global Search Palette (⌃⌥F)")
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(ODTheme.softFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(ODTheme.hairline, lineWidth: 0.5)
        )
    }

    private var inlineSearchResults: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(viewModel.searchResults.prefix(4)) { entry in
                HStack(spacing: 8) {
                    Image(systemName: entry.item.isFolder ? "folder.fill" : "doc.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)

                    Text(entry.item.shownAs)
                        .font(.caption)
                        .lineLimit(1)

                    Spacer()

                    Button {
                        Task { await viewModel.togglePin(item: entry.item, in: entry.account) }
                    } label: {
                        Image(systemName: entry.item.pinned ? "pin.fill" : "pin")
                            .font(.caption2)
                            .foregroundStyle(entry.item.pinned ? ODTheme.saving : .secondary)
                    }
                    .buttonStyle(.borderless)

                    Text(entry.item.size.formattedFileSize)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 6)
                .frame(height: 24)
            }
        }
    }

    private var uploadsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(viewModel.pendingUploads.prefix(3)) { up in
                let pct = up.size > 0 ? Int((Double(up.offset) / Double(up.size)) * 100) : 0
                HStack(spacing: 8) {
                    Image(systemName: up.state == .paused ? "pause.circle.fill" : "arrow.up.circle.fill")
                        .font(.caption)
                        .foregroundStyle(up.state == .paused ? ODTheme.warning : (up.state == .failed ? ODTheme.danger : ODTheme.ink))
                        .frame(width: 16)

                    Text(up.name)
                        .font(.caption)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    if up.state == .failed || up.state == .paused {
                        Text(up.state == .paused ? "paused" : "failed")
                            .font(.caption2)
                            .foregroundStyle(up.state == .paused ? ODTheme.warning : ODTheme.danger)
                        Button {
                            guard !viewModel.isSeedMode else { return }
                            Task { await viewModel.retryUpload(up) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .help("Retry")
                    } else {
                        Text("\(pct)%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Button {
                        guard !viewModel.isSeedMode else { return }
                        Task { await viewModel.cancelUpload(up) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel upload")
                }
                .padding(.horizontal, 6)
                .frame(height: 24)
            }
        }
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Connected Drives")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)

            if viewModel.accounts.isEmpty {
                HStack {
                    Text("No accounts configured yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Settings…") {
                        viewModel.selectedSettingsTab = .accounts
                        presentWindow { openSettings() }
                    }
                    .buttonStyle(ODPillButtonStyle(variant: .primary, compact: true))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            } else {
                ForEach(viewModel.accounts) { acc in
                    let unlocked = !acc.encryptionEnabled || viewModel.unlockedAccountIds.contains(acc.id)
                    HStack(spacing: 8) {
                        Image(systemName: acc.encryptionEnabled
                              ? (unlocked ? "lock.open.fill" : "lock.fill")
                              : "cloud.fill")
                            .font(.caption)
                            .foregroundStyle(acc.encryptionEnabled && !unlocked ? ODTheme.warning : .secondary)
                            .frame(width: 16)

                        Text(acc.displayName)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)

                        Spacer()

                        if acc.encryptionEnabled && !unlocked {
                            Text("Locked")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(ODTheme.warning)
                        } else if let accountQuota = viewModel.storageQuotasByAccountId[acc.id] {
                            Text(accountQuota.shortAvailableLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                }
            }
        }
    }

    private func presentWindow(_ openAction: () -> Void) {
        OpenDriveAppDelegate.shared?.prepareForWindowPresentation()
        openAction()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { !($0 is NSPanel) && $0.styleMask.contains(.titled) && $0.isVisible })?.makeKeyAndOrderFront(nil)
        }
    }
}

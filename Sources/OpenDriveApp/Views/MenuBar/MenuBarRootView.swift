import AppKit
import OpenDriveCore
import SwiftUI
import UniformTypeIdentifiers

/// Menu-bar popover view with mount toggle, quick search, drag-and-drop upload target,
/// active upload queue, and account status.
struct MenuBarRootView: View {
    @ObservedObject var viewModel: OpenDriveAppViewModel
    @State private var isDropTargeted: Bool = false
    @State private var selectedRecentFolderId: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "externaldrive.fill.badge.icloud")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(AppConstants.appName)
                            .font(.headline)
                        if viewModel.isNetworkOffline {
                            Text("OFFLINE")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.2))
                                .foregroundStyle(.red)
                                .cornerRadius(4)
                        } else if viewModel.isNetworkMetered {
                            Text("HOTSPOT")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.2))
                                .foregroundStyle(.orange)
                                .cornerRadius(4)
                        }
                    }
                    Text(viewModel.statusBanner)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(viewModel.mountManager.isMounted ? "Unmount" : "Mount") {
                    if viewModel.mountManager.isMounted {
                        viewModel.mountManager.unmountFilesystem()
                    } else {
                        viewModel.mountManager.mountFilesystem()
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Google Drive files (⌃⌥F)...", text: $viewModel.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await viewModel.performPaletteSearch() }
                    }
                Button("⌃⌥F") {
                    viewModel.paletteController?.togglePalette()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if !viewModel.searchResults.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.searchResults.prefix(5), id: \.item.driveId) { entry in
                        HStack {
                            Image(systemName: entry.item.isFolder ? "folder.fill" : "doc.fill")
                            Text(entry.item.shownAs)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                Task { await viewModel.togglePin(item: entry.item, in: entry.account) }
                            } label: {
                                Image(systemName: entry.item.pinned ? "pin.fill" : "pin")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            Text(entry.item.size.formattedFileSize)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
            }

            VStack(alignment: .center, spacing: 6) {
                HStack {
                    Image(systemName: "tray.and.arrow.up.fill")
                    Text("Drop files here to upload to Google Drive")
                        .font(.caption.weight(.medium))
                }
                if !viewModel.recentFolders.isEmpty {
                    Picker("Target:", selection: $selectedRecentFolderId) {
                        Text("Root Folder").tag(String?.none)
                        ForEach(viewModel.recentFolders) { folder in
                            Text(folder.name).tag(Optional(folder.id))
                        }
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5])
                    )
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                Task {
                    var droppedURLs: [URL] = []
                    for provider in providers {
                        if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                           let data = item as? Data,
                           let url = URL(dataRepresentation: data, relativeTo: nil) {
                            droppedURLs.append(url)
                        }
                    }
                    if !droppedURLs.isEmpty {
                        await viewModel.enqueueDroppedFiles(urls: droppedURLs, targetFolderId: selectedRecentFolderId)
                    }
                }
                return true
            }

            if !viewModel.pendingUploads.isEmpty {
                Divider()
                Text("Uploads (\(viewModel.pendingUploads.count))")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                ForEach(viewModel.pendingUploads.prefix(3)) { up in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(up.name)
                                .font(.caption)
                                .lineLimit(1)
                            Text("\(up.state.rawValue) • \(up.offset.formattedFileSize) / \(up.size.formattedFileSize)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancel") {
                            Task { await viewModel.cancelUpload(up) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }

            Divider()

            Text("Connected Google Drive Accounts (\(viewModel.accounts.count))")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            if viewModel.accounts.isEmpty {
                Text("No accounts configured yet. Open Settings (⌘,) to sign in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.accounts) { acc in
                    HStack {
                        Image(systemName: acc.encryptionEnabled
                              ? (viewModel.unlockedAccountIds.contains(acc.id) ? "lock.open.fill" : "lock.fill")
                              : "cloud.fill")
                        Text(acc.displayName)
                        if let email = acc.email {
                            Text("(\(email))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if acc.encryptionEnabled && !viewModel.unlockedAccountIds.contains(acc.id) {
                            Text("Locked")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Button("Open in Finder") {
                    NSWorkspace.shared.open(OpenDrivePaths.mountRootURL)
                }
                Button("Refresh Sync") {
                    DarwinNotifier.shared.post(.signal)
                }
                Button("Clear Cache") {
                    viewModel.clearChunkCache()
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 410)
    }
}

import AppKit
import OpenDriveCore
import SwiftUI

/// Spotlight-style global command palette view (`⌃⌥F`).
struct GlobalPaletteView: View {
    @ObservedObject var viewModel: OpenDriveAppViewModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ODStatusCircle(
                    size: 26,
                    systemImage: "magnifyingglass",
                    background: ODTheme.ink,
                    foreground: ODTheme.onInk
                )

                TextField("Search across all mounted Google Drives (⌃⌥F)…", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onChange(of: viewModel.searchQuery) { _, _ in
                        Task { await viewModel.performPaletteSearch() }
                    }
                    .onSubmit {
                        if let first = viewModel.searchResults.first {
                            if !viewModel.isSeedMode {
                                NSWorkspace.shared.open(viewModel.localVFSURL(for: first))
                            }
                            onClose()
                        }
                    }

                Button("Esc") {
                    onClose()
                }
                .buttonStyle(ODPillButtonStyle(variant: .secondary, compact: true))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ODTheme.cardBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(ODTheme.hairline, lineWidth: 0.5)
            )

            Rectangle()
                .fill(ODTheme.hairline)
                .frame(height: 0.5)

            if viewModel.searchResults.isEmpty {
                ContentUnavailableView {
                    Label("No Matching Files", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("Try another filename or phrase across your mounted accounts.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(viewModel.searchResults) { entry in
                            HStack(spacing: 10) {
                                ODStatusCircle(
                                    size: 28,
                                    systemImage: entry.item.isFolder
                                        ? "folder.fill"
                                        : (entry.item.isEncrypted ? "lock.doc.fill" : "doc.text.fill"),
                                    background: entry.item.isEncrypted ? ODTheme.warningBg : ODTheme.softFill,
                                    foreground: entry.item.isEncrypted ? ODTheme.warning : ODTheme.ink
                                )

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(entry.item.shownAs)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(1)
                                        if entry.item.pinned {
                                            ODBadgePill(
                                                text: "Pinned",
                                                foreground: ODTheme.saving,
                                                background: ODTheme.savingBg
                                            )
                                        }
                                    }
                                    Text("\(entry.account.displayName)\(entry.parentFolderBreadcrumb.isEmpty ? "" : " / \(entry.parentFolderBreadcrumb)") • \(entry.item.size.formattedFileSize)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 6)

                                Button {
                                    Task { await viewModel.togglePin(item: entry.item, in: entry.account) }
                                } label: {
                                    Image(systemName: entry.item.pinned ? "pin.fill" : "pin")
                                        .foregroundStyle(entry.item.pinned ? ODTheme.saving : .secondary)
                                }
                                .buttonStyle(.borderless)
                                .help(entry.item.pinned ? "Pinned offline" : "Pin file offline")

                                Button("Reveal") {
                                    guard !viewModel.isSeedMode else {
                                        onClose()
                                        return
                                    }
                                    let url = viewModel.localVFSURL(for: entry)
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                    onClose()
                                }
                                .buttonStyle(ODPillButtonStyle(variant: .secondary, compact: true))

                                Button("Open") {
                                    guard !viewModel.isSeedMode else {
                                        onClose()
                                        return
                                    }
                                    let url = viewModel.localVFSURL(for: entry)
                                    NSWorkspace.shared.open(url)
                                    onClose()
                                }
                                .buttonStyle(ODPillButtonStyle(variant: .primary, compact: true))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(ODTheme.cardBg.opacity(0.92))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(ODTheme.hairline, lineWidth: 0.5)
                            )
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 580, height: 380)
        .background(.ultraThinMaterial)
        .task {
            await viewModel.performPaletteSearch()
        }
    }
}

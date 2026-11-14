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
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField("Search across all mounted Google Drives (⌃⌥F)...", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onChange(of: viewModel.searchQuery) { _, _ in
                        Task { await viewModel.performPaletteSearch() }
                    }
                    .onSubmit {
                        if let first = viewModel.searchResults.first {
                            NSWorkspace.shared.open(viewModel.localVFSURL(for: first.item, in: first.account))
                            onClose()
                        }
                    }
                Button("Esc") {
                    onClose()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.searchResults, id: \.item.driveId) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.item.isFolder ? "folder.fill" : "doc.text.fill")
                                .foregroundStyle(entry.item.isFolder ? .blue : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.item.shownAs)
                                    .font(.body.weight(.medium))
                                    .lineLimit(1)
                                Text("\(entry.account.displayName) • \(entry.item.size.formattedFileSize)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                Task { await viewModel.togglePin(item: entry.item, in: entry.account) }
                            } label: {
                                Image(systemName: entry.item.pinned ? "pin.fill" : "pin")
                            }
                            .buttonStyle(.borderless)
                            .help(entry.item.pinned ? "Pinned offline" : "Pin file offline")

                            Button("Reveal") {
                                let url = viewModel.localVFSURL(for: entry.item, in: entry.account)
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                                onClose()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Open") {
                                let url = viewModel.localVFSURL(for: entry.item, in: entry.account)
                                NSWorkspace.shared.open(url)
                                onClose()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
                        .cornerRadius(8)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 580, height: 380)
        .task {
            await viewModel.performPaletteSearch()
        }
    }
}

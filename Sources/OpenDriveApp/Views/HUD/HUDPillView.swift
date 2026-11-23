import OpenDriveCore
import SwiftUI

/// Translucent floating pill view displaying active upload progress or eject-guard warnings.
struct HUDPillView: View {
    @ObservedObject var viewModel: OpenDriveAppViewModel

    var body: some View {
        let first = viewModel.pendingUploads.first
        let fraction = (first != nil && first!.size > 0)
            ? Double(first!.offset) / Double(first!.size)
            : 0.0

        HStack(spacing: 10) {
            ODStatusCircle(
                size: 24,
                systemImage: viewModel.hudAlertMessage != nil ? "exclamationmark.triangle.fill" : "arrow.up",
                background: viewModel.hudAlertMessage != nil ? ODTheme.warningBg : ODTheme.ink,
                foreground: viewModel.hudAlertMessage != nil ? ODTheme.warning : ODTheme.onInk
            )

            VStack(alignment: .leading, spacing: 3) {
                if let alert = viewModel.hudAlertMessage {
                    Text(alert)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ODTheme.warning)
                        .lineLimit(1)
                } else if let first {
                    Text("Uploading \(first.name)")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)

                    if let err = first.lastError, !err.isEmpty {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(first.state == .paused ? ODTheme.warning : ODTheme.danger)
                            .lineLimit(1)
                    } else {
                        Text("\(viewModel.pendingUploads.count) file(s) · \(first.offset.formattedFileSize) / \(first.size.formattedFileSize)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    ODProgressTrack(fraction: fraction, height: 3)
                }
            }

            Spacer(minLength: 4)

            if let first {
                if first.state == .failed || first.state == .paused {
                    Button {
                        guard !viewModel.isSeedMode else { return }
                        Task { await viewModel.retryUpload(first) }
                    } label: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Retry upload")
                }

                Button {
                    guard !viewModel.isSeedMode else { return }
                    Task { await viewModel.cancelUpload(first) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Cancel upload")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(ODTheme.hairline, lineWidth: 0.5)
        )
    }
}

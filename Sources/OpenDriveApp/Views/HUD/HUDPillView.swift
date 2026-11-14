import SwiftUI

/// Translucent floating pill view displaying active upload progress or eject-guard warnings.
struct HUDPillView: View {
    @ObservedObject var viewModel: OpenDriveAppViewModel

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                if let alert = viewModel.hudAlertMessage {
                    Text(alert)
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                } else if let first = viewModel.pendingUploads.first {
                    Text("Uploading \(first.name)")
                        .font(.caption.bold())
                        .lineLimit(1)
                    Text("\(viewModel.pendingUploads.count) file(s) in queue • \(first.offset.formattedFileSize) / \(first.size.formattedFileSize)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let first = viewModel.pendingUploads.first {
                Button {
                    Task { await viewModel.cancelUpload(first) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }
}

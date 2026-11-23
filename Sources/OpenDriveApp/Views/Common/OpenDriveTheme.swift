import AppKit
import OpenDriveCore
import SwiftUI
import UniformTypeIdentifiers

/// Shared dynamic palette and tactile macOS components aligned with the Open Drive showcase UI.
enum ODTheme {
    private static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? dark : light
        })
    }

    static let canvasBg = dynamicColor(
        light: NSColor(srgbRed: 0.961, green: 0.961, blue: 0.961, alpha: 1),   // #F5F5F5
        dark: NSColor(srgbRed: 0.078, green: 0.078, blue: 0.086, alpha: 1)     // #141416
    )

    static let cardBg = dynamicColor(
        light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),         // #FFFFFF
        dark: NSColor(srgbRed: 0.118, green: 0.118, blue: 0.129, alpha: 1)     // #1E1E21
    )

    static let softFill = dynamicColor(
        light: NSColor(srgbRed: 0.949, green: 0.949, blue: 0.957, alpha: 1),   // #F2F2F4
        dark: NSColor(srgbRed: 0.165, green: 0.165, blue: 0.180, alpha: 1)     // #2A2A2E
    )

    static let hoverFill = dynamicColor(
        light: NSColor(white: 0.0, alpha: 0.055),
        dark: NSColor(white: 1.0, alpha: 0.085)
    )

    static let hairline = dynamicColor(
        light: NSColor(white: 0.0, alpha: 0.09),
        dark: NSColor(white: 1.0, alpha: 0.10)
    )

    static let ink = dynamicColor(
        light: NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1),   // #1D1D1F
        dark: NSColor(srgbRed: 0.961, green: 0.961, blue: 0.969, alpha: 1)     // #F5F5F7
    )

    static let onInk = dynamicColor(
        light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),         // #FFFFFF
        dark: NSColor(srgbRed: 0.067, green: 0.067, blue: 0.075, alpha: 1)     // #111113
    )

    static let dropSpotBg = dynamicColor(
        light: NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1),   // #1D1D1F
        dark: NSColor(srgbRed: 0.141, green: 0.141, blue: 0.157, alpha: 1)     // #242428
    )

    static let dropSpotBorder = dynamicColor(
        light: NSColor(white: 1.0, alpha: 0.12),
        dark: NSColor(white: 1.0, alpha: 0.15)
    )

    static let saving = dynamicColor(
        light: NSColor(srgbRed: 0.094, green: 0.439, blue: 0.227, alpha: 1),   // #18703A
        dark: NSColor(srgbRed: 0.196, green: 0.843, blue: 0.294, alpha: 1)     // #32D74B
    )

    static let savingBg = dynamicColor(
        light: NSColor(srgbRed: 0.851, green: 0.949, blue: 0.882, alpha: 1),   // #D9F2E1
        dark: NSColor(srgbRed: 0.196, green: 0.843, blue: 0.294, alpha: 0.16)
    )

    static let warning = dynamicColor(
        light: NSColor(srgbRed: 0.698, green: 0.314, blue: 0.0, alpha: 1),     // #B25000
        dark: NSColor(srgbRed: 1.0, green: 0.624, blue: 0.039, alpha: 1)       // #FF9F0A
    )

    static let warningBg = dynamicColor(
        light: NSColor(srgbRed: 1.0, green: 0.941, blue: 0.859, alpha: 1),     // #FFF0DB
        dark: NSColor(srgbRed: 1.0, green: 0.624, blue: 0.039, alpha: 0.16)
    )

    static let danger = dynamicColor(
        light: NSColor(srgbRed: 0.769, green: 0.169, blue: 0.110, alpha: 1),   // #C42B1C
        dark: NSColor(srgbRed: 1.0, green: 0.271, blue: 0.227, alpha: 1)       // #FF453A
    )

    static let dangerBg = dynamicColor(
        light: NSColor(srgbRed: 0.988, green: 0.910, blue: 0.902, alpha: 1),   // #FCE8E6
        dark: NSColor(srgbRed: 1.0, green: 0.271, blue: 0.227, alpha: 0.16)
    )

    static let segmentTrack = dynamicColor(
        light: NSColor(srgbRed: 0.898, green: 0.898, blue: 0.918, alpha: 1),   // #E5E5EA
        dark: NSColor(srgbRed: 0.180, green: 0.180, blue: 0.196, alpha: 1)     // #2E2E32
    )

    static let segmentColors: [Color] = [
        dynamicColor(
            light: NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1), // #1D1D1F
            dark: NSColor(srgbRed: 0.961, green: 0.961, blue: 0.969, alpha: 1)   // #F5F5F7
        ),
        dynamicColor(
            light: NSColor(srgbRed: 0.431, green: 0.431, blue: 0.451, alpha: 1), // #6E6E73
            dark: NSColor(srgbRed: 0.557, green: 0.557, blue: 0.576, alpha: 1)   // #8E8E93
        ),
        dynamicColor(
            light: NSColor(srgbRed: 0.682, green: 0.682, blue: 0.698, alpha: 1), // #AEAEB2
            dark: NSColor(srgbRed: 0.329, green: 0.329, blue: 0.345, alpha: 1)   // #545458
        ),
    ]
}

extension String {
    var abbreviatingHomeDirectory: String {
        (self as NSString).abbreviatingWithTildeInPath
    }
}

/// Clean rounded card surface matching the website's tactile card styling.
struct ODCard<Content: View>: View {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 14
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(ODTheme.cardBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(ODTheme.hairline, lineWidth: 0.5)
            )
            .shadow(
                color: Color.black.opacity(colorScheme == .light ? 0.035 : 0.22),
                radius: colorScheme == .light ? 6 : 8,
                x: 0,
                y: 2
            )
    }
}

struct ODSectionHeader: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 2)
    }
}

struct ODStatusCircle: View {
    var size: CGFloat = 32
    let systemImage: String
    var background: Color = ODTheme.ink
    var foreground: Color = ODTheme.onInk

    var body: some View {
        ZStack {
            Circle()
                .fill(background)
                .frame(width: size, height: size)
            Image(systemName: systemImage)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(foreground)
        }
    }
}

struct ODBadgePill: View {
    let text: String
    var dotColor: Color? = nil
    var systemImage: String? = nil
    var foreground: Color = ODTheme.ink
    var background: Color = ODTheme.softFill

    var body: some View {
        HStack(spacing: 5) {
            if let dotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(background))
    }
}

struct ODPillButtonStyle: ButtonStyle {
    enum Variant {
        case primary
        case secondary
        case destructive
    }

    var variant: Variant = .secondary
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        ODPillButtonBody(
            configuration: configuration,
            variant: variant,
            compact: compact
        )
    }

    private struct ODPillButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let variant: Variant
        let compact: Bool

        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font((compact ? Font.caption : Font.subheadline).weight(.medium))
                .foregroundStyle(foregroundColor)
                .padding(.horizontal, compact ? 10 : 14)
                .frame(height: compact ? 25 : 30)
                .background(Capsule().fill(backgroundColor))
                .overlay(
                    Capsule()
                        .strokeBorder(borderColor, lineWidth: 0.5)
                )
                .opacity(effectiveOpacity)
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { hovering in
                    isHovered = hovering
                }
        }

        private var foregroundColor: Color {
            switch variant {
            case .primary: return ODTheme.onInk
            case .secondary: return .primary
            case .destructive: return ODTheme.danger
            }
        }

        private var backgroundColor: Color {
            switch variant {
            case .primary:
                return isHovered ? ODTheme.ink.opacity(0.86) : ODTheme.ink
            case .secondary:
                return isHovered ? ODTheme.hoverFill : ODTheme.softFill
            case .destructive:
                return isHovered ? ODTheme.dangerBg.opacity(1.25) : ODTheme.dangerBg
            }
        }

        private var borderColor: Color {
            switch variant {
            case .primary: return Color.clear
            case .secondary: return ODTheme.hairline
            case .destructive: return ODTheme.danger.opacity(0.25)
            }
        }

        private var effectiveOpacity: Double {
            if !isEnabled { return 0.45 }
            if configuration.isPressed { return 0.9 }
            return 1.0
        }
    }
}

struct ODProgressTrack: View {
    var fraction: Double
    var tint: Color = ODTheme.ink
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(ODTheme.segmentTrack)
                Capsule()
                    .fill(tint)
                    .frame(width: max(clamped > 0 ? height : 0, proxy.size.width * clamped))
            }
        }
        .frame(height: height)
    }
}

struct ODStorageSegment: Identifiable {
    let id: String
    let name: String
    let usedBytes: Int64
}

/// Multi-segment quota bar modeled after the website's macOS Storage card.
struct ODSegmentedQuotaBar: View {
    let quota: CloudStorageQuota
    var segments: [ODStorageSegment] = []
    var showZeroLocalBadge: Bool = false
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            if let total = quota.totalBytes,
               let available = quota.availableBytes {
                HStack(alignment: .center, spacing: 8) {
                    Text("\(available.formattedFileSize) available")
                        .font((compact ? Font.caption : Font.headline).weight(.semibold))
                        .monospacedDigit()

                    if showZeroLocalBadge && !compact {
                        ODBadgePill(
                            text: "Zero KB local",
                            foreground: ODTheme.saving,
                            background: ODTheme.savingBg
                        )
                    }

                    Spacer()

                    Text("\(quota.usedBytes.formattedFileSize) of \(total.formattedFileSize) used")
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                segmentedBar(totalBytes: max(total, 1))

                if !compact && !displaySegments.isEmpty {
                    HStack(spacing: 14) {
                        ForEach(Array(displaySegments.enumerated()), id: \.element.id) { idx, segment in
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(ODTheme.segmentColors[idx % ODTheme.segmentColors.count])
                                    .frame(width: 7, height: 7)
                                Text(segment.name)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        HStack(spacing: 5) {
                            Circle()
                                .fill(ODTheme.segmentTrack)
                                .frame(width: 7, height: 7)
                            Text("Free")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            } else {
                HStack {
                    Text("\(quota.usedBytes.formattedFileSize) used · Unlimited storage")
                        .font(compact ? .caption : .subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if showZeroLocalBadge && !compact {
                        ODBadgePill(
                            text: "Zero KB local",
                            foreground: ODTheme.saving,
                            background: ODTheme.savingBg
                        )
                    }
                }
            }
        }
    }

    private var displaySegments: [ODStorageSegment] {
        let nonZero = segments.filter { $0.usedBytes > 0 }
        if !nonZero.isEmpty {
            return nonZero
        }
        return quota.usedBytes > 0
            ? [ODStorageSegment(id: "used", name: "Used", usedBytes: quota.usedBytes)]
            : []
    }

    @ViewBuilder
    private func segmentedBar(totalBytes: Int64) -> some View {
        let barHeight: CGFloat = compact ? 7 : 11
        GeometryReader { proxy in
            let width = proxy.size.width
            let active = displaySegments
            let gap: CGFloat = 1.5
            let totalGap = CGFloat(max(0, active.count - 1)) * gap
            let usableWidth = max(0, width - totalGap)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: barHeight / 2, style: .continuous)
                    .fill(ODTheme.segmentTrack)

                HStack(spacing: gap) {
                    ForEach(Array(active.enumerated()), id: \.element.id) { idx, segment in
                        let ratio = min(1.0, max(0.0, Double(segment.usedBytes) / Double(totalBytes)))
                        let segWidth = max(ratio > 0 ? 4 : 0, usableWidth * ratio)
                        Rectangle()
                            .fill(ODTheme.segmentColors[idx % ODTheme.segmentColors.count])
                            .frame(width: segWidth, height: barHeight)
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: barHeight / 2, style: .continuous))
            }
        }
        .frame(height: barHeight)
    }
}

/// Dark charcoal rounded drop target matching the website's "drop files to upload" panel.
struct ODDropZoneCard: View {
    @ObservedObject var viewModel: OpenDriveAppViewModel
    @Binding var selectedAccountId: String?
    @Binding var selectedRecentFolderId: String?
    var compact: Bool = false

    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            VStack(spacing: compact ? 4 : 6) {
                Image(systemName: isDropTargeted ? "arrow.down.circle.fill" : "icloud.and.arrow.up.fill")
                    .font(.system(size: compact ? 18 : 22, weight: .semibold))
                    .foregroundStyle(.white)

                Text(isDropTargeted ? "Release to upload" : "Drop files here to upload to Google Drive")
                    .font((compact ? Font.caption : Font.subheadline).weight(.semibold))
                    .foregroundStyle(.white)

                Text("\(targetAccountName) · \(targetFolderName)")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.68))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, compact ? 14 : 20)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: compact ? 11 : 13, style: .continuous)
                    .fill(ODTheme.dropSpotBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 11 : 13, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? Color.white.opacity(0.65) : ODTheme.dropSpotBorder,
                        style: StrokeStyle(lineWidth: isDropTargeted ? 1.5 : 1, dash: isDropTargeted ? [] : [5, 4])
                    )
            )
            .scaleEffect(isDropTargeted ? 0.99 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isDropTargeted)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                guard !viewModel.isSeedMode else { return false }
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
                        await viewModel.enqueueDroppedFiles(
                            urls: droppedURLs,
                            targetAccountId: selectedAccountId,
                            targetFolderId: selectedRecentFolderId
                        )
                    }
                }
                return true
            }

            let scopedFolders = viewModel.recentFolders(for: selectedAccountId)
            if viewModel.accounts.count > 1 || !scopedFolders.isEmpty {
                if compact {
                    HStack(spacing: 8) {
                        if viewModel.accounts.count > 1 {
                            Picker("Account", selection: $selectedAccountId) {
                                Text(viewModel.accounts.first?.displayName ?? AppConstants.defaultAccountName)
                                    .tag(String?.none)
                                ForEach(viewModel.accounts.dropFirst()) { account in
                                    Text(account.displayName).tag(Optional(account.id))
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .onChange(of: selectedAccountId) { _, _ in
                                selectedRecentFolderId = nil
                            }
                        }

                        if !scopedFolders.isEmpty {
                            Picker("Target", selection: $selectedRecentFolderId) {
                                Text("Root Folder").tag(String?.none)
                                ForEach(scopedFolders) { folder in
                                    Text(folder.name).tag(Optional(folder.id))
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 2)
                } else {
                    HStack(spacing: 12) {
                        if viewModel.accounts.count > 1 {
                            Picker("Account:", selection: $selectedAccountId) {
                                Text(viewModel.accounts.first?.displayName ?? AppConstants.defaultAccountName)
                                    .tag(String?.none)
                                ForEach(viewModel.accounts.dropFirst()) { account in
                                    Text(account.displayName).tag(Optional(account.id))
                                }
                            }
                            .controlSize(.small)
                            .onChange(of: selectedAccountId) { _, _ in
                                selectedRecentFolderId = nil
                            }
                        }

                        if !scopedFolders.isEmpty {
                            Picker("Target:", selection: $selectedRecentFolderId) {
                                Text("Root Folder").tag(String?.none)
                                ForEach(scopedFolders) { folder in
                                    Text(folder.name).tag(Optional(folder.id))
                                }
                            }
                            .controlSize(.small)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
    }

    private var targetAccountName: String {
        if let id = selectedAccountId,
           let matched = viewModel.accounts.first(where: { $0.id == id }) {
            return matched.displayName
        }
        return viewModel.accounts.first?.displayName ?? AppConstants.defaultAccountName
    }

    private var targetFolderName: String {
        let scopedFolders = viewModel.recentFolders(for: selectedAccountId)
        if let id = selectedRecentFolderId,
           let matched = scopedFolders.first(where: { $0.id == id }) {
            return matched.name
        }
        return "Root Folder"
    }
}

/// Cryptographic spec preview matching Moment 5 of the website.
struct ODVaultSpecCard: View {
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack(spacing: 6) {
                specChip("ODE1 72 B Header")
                specChip("AES-256-GCM")
                specChip("ODNames-v1")
                if !compact {
                    specChip(".od-meta")
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("magic: \"ODE1\" (0x4F 0x44 0x45 0x31)")
                Text("kdf:   PBKDF2-HMAC-SHA256 (210,000 ops)")
                Text("chunk: 4 MiB + 16 B GCM authentication tag")
                if !compact {
                    Text("meta:  .od-meta + 24-word US-Letter recovery PDF")
                }
            }
            .font(.system(size: compact ? 10.5 : 11, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.84))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(compact ? 9 : 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.32))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            )
        }
        .padding(compact ? 11 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(ODTheme.dropSpotBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(ODTheme.dropSpotBorder, lineWidth: 0.5)
        )
    }

    private func specChip(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.11)))
    }
}

/// Hover-aware macOS menu row matching the website's menu-bar panel.
struct ODMenuActionRow: View {
    let title: String
    let systemImage: String
    var shortcut: String? = nil
    var role: ButtonRole? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(role == .destructive ? ODTheme.danger : .secondary)
                    .frame(width: 16, alignment: .center)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(role == .destructive ? ODTheme.danger : .primary)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered ? ODTheme.hoverFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

import AppKit
import OpenDriveCore
import SwiftUI

/// Multi-tab macOS Settings window (`General`, `Accounts & Vault`, `Network`).
struct SettingsView: View {
    @ObservedObject var viewModel: OpenDriveAppViewModel
    @State private var newAccountName = "My Google Drive"
    @State private var newAccountEmail = ""
    @State private var unlockInput = ""
    @State private var showCustomOAuthFields = false

    var body: some View {
        TabView(selection: $viewModel.selectedSettingsTab) {
            generalTab
                .tabItem {
                    Label(SettingsTab.general.title, systemImage: SettingsTab.general.symbolName)
                }
                .tag(SettingsTab.general)

            accountsAndVaultTab
                .tabItem {
                    Label(SettingsTab.accounts.title, systemImage: SettingsTab.accounts.symbolName)
                }
                .tag(SettingsTab.accounts)

            networkTab
                .tabItem {
                    Label(SettingsTab.network.title, systemImage: SettingsTab.network.symbolName)
                }
                .tag(SettingsTab.network)
        }
        .noInitialFocus()
        .onAppear {
            if !viewModel.isSeedMode {
                OpenDriveAppDelegate.shared?.prepareForWindowPresentation()
            }
            viewModel.refreshLaunchAtLoginStatus()
        }
    }

    // MARK: - Tabs

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Launch Open Drive at Login", isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { viewModel.setLaunchAtLogin($0) }
                ))
                .controlSize(.mini)

                if viewModel.launchAtLoginRequiresApproval {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Approval required in macOS Login Items.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items…") {
                            viewModel.openLoginItemsSettings()
                        }
                        .buttonStyle(.link)
                        .controlSize(.small)
                    }
                }

                if let launchErr = viewModel.launchAtLoginError, !launchErr.isEmpty {
                    Text(launchErr)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Toggle("Hide from Dock when all windows are closed", isOn: $viewModel.hideDockIconWhenClosed)
                    .controlSize(.mini)
                Toggle("Enable Global Search Shortcut (⌃⌥F)", isOn: $viewModel.searchHotkeyEnabled)
                    .controlSize(.mini)
            } header: {
                Text("Startup & Menu Bar")
            } footer: {
                Text("When hidden from the Dock, Open Drive stays running in the menu bar after you close all windows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Mount Mode", selection: $viewModel.mountBackendMode) {
                    ForEach(MountBackendMode.allCases, id: \.self) { mode in
                        Text(mode.displayTitle).tag(mode)
                    }
                }
                LabeledContent("Drive Name") {
                    HStack(spacing: 8) {
                        Text(viewModel.mountedDriveName)
                            .foregroundStyle(.secondary)
                        MountedDriveRenameButton(viewModel: viewModel, usePillStyle: true, compactPill: true)
                    }
                }
                HStack {
                    VStack(alignment: .leading) {
                        Text("Mount Path: \(viewModel.mountManager.activeMountURL.path.abbreviatingHomeDirectory)")
                            .font(.body.weight(.medium))
                        Text(viewModel.mountManager.lastMountMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(viewModel.mountManager.isMounted ? "Unmount Volume" : "Mount Volume") {
                        guard !viewModel.isSeedMode else { return }
                        if viewModel.mountManager.isMounted {
                            viewModel.mountManager.unmountFilesystem()
                        } else {
                            viewModel.mountManager.mountFilesystem()
                        }
                    }
                    .buttonStyle(ODPillButtonStyle(variant: .secondary, compact: true))
                }
            } header: {
                Text("Filesystem Mount")
            } footer: {
                Text("Virtual Disk reports your actual Google Drive available space in Finder and Get Info. CloudStorage uses Apple's File Provider extension, where Finder displays your startup disk's free space.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Streaming Chunk Cache (~/Library/Caches/OpenDrive/chunks)") {
                HStack {
                    Text("Max Local Disk Cache:")
                    Slider(value: $viewModel.maxCacheGiB, in: 1...50, step: 1)
                    Text("\(Int(viewModel.maxCacheGiB)) GiB")
                        .monospacedDigit()
                        .frame(width: 55, alignment: .trailing)
                }
                Button("Purge Cached Chunks Now") {
                    guard !viewModel.isSeedMode else { return }
                    viewModel.clearChunkCache()
                }
                .buttonStyle(ODPillButtonStyle(variant: .secondary, compact: true))
            }
        }
        .formStyle(.grouped)
        .fitsContent()
        .frame(width: 580)
    }

    private var accountsAndVaultTab: some View {
        Form {
            Section {
                if !viewModel.hasBundledOAuthCredentials {
                    TextField(
                        "Google OAuth Client ID",
                        text: $viewModel.googleClientId,
                        prompt: Text("xxxx.apps.googleusercontent.com")
                    )
                    SecureField(
                        "Google Client Secret",
                        text: $viewModel.googleClientSecret,
                        prompt: Text("GOCSPX-… (from Desktop OAuth client)")
                    )
                }

                TextField(
                    "Mount Folder Display Name",
                    text: $newAccountName,
                    prompt: Text("My Google Drive")
                )
                Toggle("Mount Whole Google Drive (instead of dedicated Open Drive folder)", isOn: $viewModel.wholeDriveMode)
                    .controlSize(.mini)
                Toggle("Enable Zero-Knowledge Encryption (ODE1 + ODNames)", isOn: $viewModel.encryptionEnabled)
                    .controlSize(.mini)
                if viewModel.encryptionEnabled {
                    SecureField(
                        "Vault Passphrase",
                        text: $viewModel.vaultPassphrase,
                        prompt: Text("Choose a strong passphrase")
                    )
                    ODVaultSpecCard(compact: true)
                        .padding(.vertical, 2)
                }

                HStack {
                    let signInTitle = viewModel.isOAuthInProgress
                        ? "Waiting for Browser…"
                        : (viewModel.hasBundledOAuthCredentials ? "Sign in with Google" : "Sign in with Google (Browser PKCE)")
                    Button(signInTitle) {
                        Task {
                            await viewModel.signInWithGoogleBrowser(displayName: newAccountName)
                        }
                    }
                    .buttonStyle(ODPillButtonStyle(variant: .primary))
                    .disabled(viewModel.isOAuthInProgress)

                    if viewModel.isOAuthInProgress {
                        Button("Cancel") {
                            viewModel.cancelGoogleSignIn()
                        }
                        .buttonStyle(ODPillButtonStyle(variant: .secondary))
                    }

                    Button("Add Offline / Local Account") {
                        Task {
                            await viewModel.addGoogleDriveAccount(displayName: newAccountName, email: newAccountEmail)
                        }
                    }
                    .buttonStyle(ODPillButtonStyle(variant: .secondary))
                }

                if viewModel.hasBundledOAuthCredentials {
                    DisclosureGroup("Custom OAuth Credentials (Optional)", isExpanded: $showCustomOAuthFields) {
                        TextField(
                            "Google OAuth Client ID",
                            text: $viewModel.googleClientId,
                            prompt: Text("xxxx.apps.googleusercontent.com")
                        )
                        SecureField(
                            "Google Client Secret",
                            text: $viewModel.googleClientSecret,
                            prompt: Text("GOCSPX-… (from Desktop OAuth client)")
                        )
                    }
                }

                if let msg = viewModel.oauthStatusMessage {
                    HStack(alignment: .top, spacing: 6) {
                        if viewModel.isOAuthInProgress {
                            ProgressView()
                                .controlSize(.small)
                        } else if viewModel.oauthStatusIsError {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(viewModel.oauthStatusIsError ? .red : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !viewModel.recoveryWords.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("24-Word Vault Recovery Phrase:")
                                .font(.caption.bold())
                            Spacer()
                            Button("Export Recovery Key PDF...") {
                                viewModel.exportRecoveryKeySheet(for: newAccountName, email: newAccountEmail)
                            }
                            .controlSize(.small)
                        }
                        Text(viewModel.recoveryWords.joined(separator: " "))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Connect Google Drive (OAuth 2.0 PKCE)")
            } footer: {
                if viewModel.hasBundledOAuthCredentials {
                    Text("Ready for one-click Google Drive sign-in using your locally bundled Desktop OAuth credentials.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 4) {
                        Text("Requires a Google Cloud Desktop app OAuth Client ID & Secret with the Google Drive API enabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Open Google Cloud Console…") {
                            if let url = URL(string: "https://console.cloud.google.com/apis/credentials") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.link)
                        .controlSize(.small)
                    }
                }
            }

            Section("Configured Accounts & Vault Unlock") {
                if viewModel.accounts.isEmpty {
                    Text("No accounts connected yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.accounts) { acc in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .center, spacing: 8) {
                                Image(systemName: acc.encryptionEnabled ? "lock.shield.fill" : "cloud.fill")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(acc.displayName)
                                        .font(.body.weight(.medium))
                                        .lineLimit(1)
                                    if let email = acc.email {
                                        Text(email)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    if let accountQuota = viewModel.storageQuotasByAccountId[acc.id] {
                                        Text(accountQuota.compactAvailableSummary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                AccountScopePicker(account: acc, viewModel: viewModel)
                                AccountRenameButton(account: acc, viewModel: viewModel, usePillStyle: true)
                                Button("Remove", role: .destructive) {
                                    guard !viewModel.isSeedMode else { return }
                                    Task { await viewModel.removeAccount(acc) }
                                }
                                .buttonStyle(ODPillButtonStyle(variant: .destructive, compact: true))
                            }
                            if acc.encryptionEnabled && !viewModel.unlockedAccountIds.contains(acc.id) {
                                HStack {
                                    SecureField("Passphrase or 24-word recovery key", text: $unlockInput)
                                    Button("Unlock Vault") {
                                        Task {
                                            _ = await viewModel.unlockVault(for: acc, secretInput: unlockInput)
                                            unlockInput = ""
                                        }
                                    }
                                    .buttonStyle(ODPillButtonStyle(variant: .primary, compact: true))
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fitsContent()
        .frame(width: 580)
    }

    private var networkTab: some View {
        Form {
            Section("Network & Upload Bandwidth") {
                Toggle("Pause Uploads on Personal Hotspot / Metered Network", isOn: $viewModel.pauseOnMetered)
                    .controlSize(.mini)
                HStack {
                    Text("Upload Bandwidth Cap:")
                    Slider(value: $viewModel.bandwidthLimitMbps, in: 0...200, step: 5)
                    Text(viewModel.bandwidthLimitMbps == 0 ? "Unlimited" : "\(Int(viewModel.bandwidthLimitMbps)) Mbps")
                        .frame(width: 80, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
        .fitsContent()
        .frame(width: 580)
    }
}

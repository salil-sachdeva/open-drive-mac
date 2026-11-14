import AppKit
import OpenDriveCore
import SwiftUI

/// Multi-tab macOS Settings window (`General`, `Accounts & Vault`, `Network & AI`).
struct SettingsView: View {
    @ObservedObject var viewModel: OpenDriveAppViewModel
    @State private var newAccountName = "My Google Drive"
    @State private var newAccountEmail = ""
    @State private var unlockInput = ""
    @State private var mcpMessage = ""

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            accountsAndVaultTab
                .tabItem {
                    Label("Accounts & Vault", systemImage: "lock.icloud")
                }

            networkAndAITab
                .tabItem {
                    Label("Network & AI", systemImage: "network")
                }
        }
        .padding(20)
        .frame(width: 580, height: 480)
    }

    // MARK: - Tabs

    private var generalTab: some View {
        Form {
            Section("Filesystem Mount (Apple FSKit)") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Mount Path: ~/Library/Open Drive")
                            .font(.body.weight(.medium))
                        Text(viewModel.mountManager.lastMountMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(viewModel.mountManager.isMounted ? "Unmount Volume" : "Mount Volume") {
                        if viewModel.mountManager.isMounted {
                            viewModel.mountManager.unmountFilesystem()
                        } else {
                            viewModel.mountManager.mountFilesystem()
                        }
                    }
                }
                Toggle("Launch Open Drive at Login", isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { viewModel.setLaunchAtLogin($0) }
                ))
                Toggle("Enable Global Search Shortcut (⌃⌥F)", isOn: $viewModel.searchHotkeyEnabled)
            }

            Section("Streaming Chunk Cache (~/Library/Caches/OpenDrive/chunks)") {
                HStack {
                    Text("Max Local Disk Cache:")
                    Slider(value: $viewModel.maxCacheGiB, in: 1...50, step: 1)
                    Text("\(Int(viewModel.maxCacheGiB)) GiB")
                        .frame(width: 55, alignment: .trailing)
                }
                Button("Purge Cached Chunks Now") {
                    viewModel.clearChunkCache()
                }
            }
        }
    }

    private var accountsAndVaultTab: some View {
        Form {
            Section("Connect Google Drive (OAuth 2.0 PKCE)") {
                TextField("Google OAuth Client ID", text: $viewModel.googleClientId)
                    .onChange(of: viewModel.googleClientId) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: AppConstants.DefaultsKey.googleClientId)
                    }
                SecureField("Client Secret (optional for Desktop apps)", text: $viewModel.googleClientSecret)
                    .onChange(of: viewModel.googleClientSecret) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: AppConstants.DefaultsKey.googleClientSecret)
                    }
                TextField("Mount Folder Display Name", text: $newAccountName)
                Toggle("Mount Whole Google Drive (instead of dedicated Open Drive folder)", isOn: $viewModel.wholeDriveMode)
                Toggle("Enable Zero-Knowledge Encryption (FDE1 + FDNames)", isOn: $viewModel.encryptionEnabled)
                if viewModel.encryptionEnabled {
                    SecureField("Vault Passphrase", text: $viewModel.vaultPassphrase)
                }

                HStack {
                    Button(viewModel.isOAuthInProgress ? "Waiting for Browser..." : "Sign in with Google (Browser PKCE)") {
                        Task {
                            await viewModel.signInWithGoogleBrowser(displayName: newAccountName)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isOAuthInProgress)

                    Button("Add Offline / Local Account") {
                        Task {
                            await viewModel.addGoogleDriveAccount(displayName: newAccountName, email: newAccountEmail)
                        }
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
            }

            Section("Configured Accounts & Vault Unlock") {
                ForEach(viewModel.accounts) { acc in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: acc.encryptionEnabled ? "lock.shield.fill" : "cloud.fill")
                            Text(acc.displayName)
                                .font(.body.weight(.medium))
                            if let email = acc.email {
                                Text("(\(email))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) {
                                Task { await viewModel.removeAccount(acc) }
                            }
                            .controlSize(.small)
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
                            }
                        }
                    }
                }
            }
        }
    }

    private var networkAndAITab: some View {
        Form {
            Section("Network & Upload Bandwidth") {
                Toggle("Pause Uploads on Personal Hotspot / Metered Network", isOn: $viewModel.pauseOnMetered)
                HStack {
                    Text("Upload Bandwidth Cap:")
                    Slider(value: $viewModel.bandwidthLimitMbps, in: 0...200, step: 5)
                    Text(viewModel.bandwidthLimitMbps == 0 ? "Unlimited" : "\(Int(viewModel.bandwidthLimitMbps)) Mbps")
                        .frame(width: 80, alignment: .trailing)
                }
            }

            Section("AI Assistant MCP Server (open-drive-mcp)") {
                HStack {
                    Button("Install for Claude Desktop") {
                        if let url = try? MCPInstaller.installForClaudeDesktop(mcpBinaryPath: AppConstants.mcpBinaryPath) {
                            mcpMessage = "Updated \(url.path)"
                        }
                    }
                    Button("Install for Cursor") {
                        if let url = try? MCPInstaller.installForCursor(mcpBinaryPath: AppConstants.mcpBinaryPath) {
                            mcpMessage = "Updated \(url.path)"
                        }
                    }
                    Button("Copy Claude Code Command") {
                        let cmd = MCPInstaller.claudeCodeCLICommand(mcpBinaryPath: AppConstants.mcpBinaryPath)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cmd, forType: .string)
                        mcpMessage = "Copied: \(cmd)"
                    }
                }
                if !mcpMessage.isEmpty {
                    Text(mcpMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

import AppKit
import OpenDriveCore
import SwiftUI

/// Entry point: hosts the main NavigationSplitView window, menu-bar status item,
/// and Settings window.
@main
struct OpenDriveApp: App {
    @NSApplicationDelegateAdaptor(OpenDriveAppDelegate.self) private var delegate
    @StateObject private var viewModel = OpenDriveAppViewModel()

    var body: some Scene {
        Window(AppConstants.appName, id: "main") {
            MainWindowHostView(viewModel: viewModel)
                .frame(minWidth: 740, minHeight: 480)
        }
        .defaultSize(width: 900, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            ToolbarCommands()
            CommandGroup(after: .sidebar) {
                Button("Global Search") {
                    viewModel.paletteController?.togglePalette()
                }
                .keyboardShortcut("f", modifiers: [.control, .option])

                Button("Refresh Sync") {
                    if !viewModel.isSeedMode {
                        DarwinNotifier.shared.post(.signal)
                        viewModel.mountManager.signalFileProviderRefresh()
                        Task { await viewModel.refreshStorageQuotas() }
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Open in Finder") {
                    NSWorkspace.shared.open(viewModel.mountManager.activeMountURL)
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
        }

        MenuBarExtra(AppConstants.appName, systemImage: "externaldrive.badge.icloud") {
            MenuBarRootView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)
    }
}

private struct MainWindowHostView: View {
    @ObservedObject var viewModel: OpenDriveAppViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        MainWindowView(viewModel: viewModel)
            .onAppear {
                OpenDriveAppDelegate.shared?.openMainWindowAction = {
                    openWindow(id: "main")
                }
                OpenDriveAppDelegate.shared?.syncDockVisibility()
                Snapshot.runIfRequested(viewModel: viewModel, openSettings: openSettings)
            }
    }
}

@MainActor
public final class OpenDriveAppDelegate: NSObject, NSApplicationDelegate {
    public static weak var shared: OpenDriveAppDelegate?
    public static weak var pendingMountManager: MountManager?
    public weak var mountManager: MountManager?
    public var openMainWindowAction: (() -> Void)?
    public var isSeedMode: Bool = false

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        if self.mountManager == nil {
            self.mountManager = Self.pendingMountManager
        }
        self.isSeedMode = (ProcessInfo.processInfo.environment["APP_SEED"] == "1")

        let processInfo = ProcessInfo.processInfo
        processInfo.disableAutomaticTermination("Open Drive stays running in the menu bar and serves mounted Google Drive files")
        processInfo.disableSuddenTermination()
        processInfo.automaticTerminationSupportEnabled = false

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let closingWindow = note.object as? NSWindow
            DispatchQueue.main.async {
                Task { @MainActor in
                    self?.syncDockVisibility(excluding: closingWindow)
                }
            }
        }
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                Task { @MainActor in
                    self?.syncDockVisibility()
                }
            }
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep the menu-bar status item and hotkey active even after closing the main window.
        false
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isSeedMode else { return .terminateNow }
        let manager = mountManager ?? Self.pendingMountManager

        if MountManager.hasActiveUploadsSync() {
            prepareForWindowPresentation()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Uploads Are Still in Progress"
            alert.informativeText = "Quitting now will pause active Google Drive uploads until you reopen Open Drive."
            alert.addButton(withTitle: "Keep Uploading")
            alert.addButton(withTitle: "Quit Anyway")
            if alert.runModal() == .alertFirstButtonReturn {
                syncDockVisibility()
                return .terminateCancel
            }
        }

        manager?.unmountSynchronouslyForTermination()
        return .terminateNow
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        prepareForWindowPresentation()
        if !flag {
            openMainWindowAction?()
        }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let win = NSApp.windows.first(where: Self.isStandardAppWindow) {
                win.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    public func prepareForWindowPresentation() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    public func syncDockVisibility(excluding closingWindow: NSWindow? = nil) {
        guard !isSeedMode else { return }
        guard SharedSettings.shared.hideDockIconWhenClosed else {
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
            }
            return
        }

        let hasOpenStandardWindow = NSApp.windows.contains { window in
            window !== closingWindow && Self.isStandardAppWindow(window)
        }
        if hasOpenStandardWindow {
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
            }
        } else {
            if NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    private static func isStandardAppWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel)
            && window.styleMask.contains(.titled)
            && window.canBecomeKey
            && (window.isVisible || window.isMiniaturized)
    }
}

import AppKit
import SwiftUI

/// Automated screenshot capture helper (`APP_SEED=1 APP_SNAPSHOT=/tmp/open-drive-shots`).
/// Captures every sidebar section and Settings tab in Light and Dark appearance and quits.
@MainActor
enum Snapshot {
    private static var hasStarted = false
    private static var screencaptureUnavailable = false

    static func runIfRequested(viewModel: OpenDriveAppViewModel, openSettings: OpenSettingsAction) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["APP_SNAPSHOT"], !dir.isEmpty, !hasStarted else { return }
        hasStarted = true

        // Snapshots never run against real user databases or Keychain items.
        guard viewModel.isSeedMode else {
            print("SNAPSHOT refused: set APP_SEED=1 to avoid reading user data")
            NSApp.terminate(nil)
            return
        }

        Task {
            // Wake the display if it went idle before running screencapture.
            let wake = Process()
            wake.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            wake.arguments = ["-u", "-t", "2"]
            try? wake.run()
            wake.waitUntilExit()

            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(1.0))

            let mainWindow = NSApp.windows.first { $0.canBecomeMain && !$0.isSheet }

            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                for section in SidebarSection.allCases {
                    viewModel.selectedSidebarItem = section
                    try? await Task.sleep(for: .milliseconds(500))
                    capture(to: "\(dir)/\(section.rawValue)-\(mode).png", window: mainWindow)
                }
            }

            openSettings()
            // Wait for SwiftUI's Settings window to instantiate and appear.
            var settingsWindow: NSWindow? = nil
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(150))
                settingsWindow = NSApp.windows.first {
                    $0.isVisible && $0 !== mainWindow && !$0.isSheet && $0.styleMask.contains(.titled)
                }
                if settingsWindow != nil { break }
            }

            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                for tab in SettingsTab.allCases {
                    viewModel.selectedSettingsTab = tab
                    try? await Task.sleep(for: .milliseconds(600))
                    settingsWindow = settingsWindow ?? NSApp.windows.first {
                        $0.isVisible && $0 !== mainWindow && !$0.isSheet && $0.styleMask.contains(.titled)
                    }
                    capture(to: "\(dir)/settings-\(tab.rawValue)-\(mode).png", window: settingsWindow)
                }
            }
            settingsWindow?.orderOut(nil)

            viewModel.paletteController?.showPalette()
            var paletteWindow: NSWindow? = nil
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
                paletteWindow = NSApp.windows.first { $0 is NSPanel && $0.isVisible }
                if paletteWindow != nil { break }
            }
            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                try? await Task.sleep(for: .milliseconds(450))
                capture(to: "\(dir)/palette-\(mode).png", window: paletteWindow)
            }
            paletteWindow?.orderOut(nil)

            // Capture MenuBarRootView & HUDPillView in Light & Dark modes.
            let menuHost = NSHostingView(
                rootView: MenuBarRootView(viewModel: viewModel)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(ODTheme.hairline, lineWidth: 0.5)
                    )
            )
            menuHost.layoutSubtreeIfNeeded()
            let menuSize = menuHost.fittingSize
            let menuPanel = NSPanel(
                contentRect: NSRect(origin: .zero, size: menuSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            menuPanel.isOpaque = false
            menuPanel.backgroundColor = .clear
            menuPanel.hasShadow = true
            menuPanel.contentView = menuHost
            menuPanel.center()
            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                try? await Task.sleep(for: .milliseconds(350))
                menuHost.layoutSubtreeIfNeeded()
                menuPanel.setContentSize(menuHost.fittingSize)
                capture(to: "\(dir)/menubar-\(mode).png", window: menuPanel)
            }
            menuPanel.orderOut(nil)

            let hudHost = NSHostingView(rootView: HUDPillView(viewModel: viewModel).frame(width: 320))
            hudHost.layoutSubtreeIfNeeded()
            let hudSize = hudHost.fittingSize
            let hudPanel = NSPanel(
                contentRect: NSRect(origin: .zero, size: hudSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            hudPanel.isOpaque = false
            hudPanel.backgroundColor = .clear
            hudPanel.hasShadow = true
            hudPanel.contentView = hudHost
            hudPanel.center()
            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                try? await Task.sleep(for: .milliseconds(300))
                hudHost.layoutSubtreeIfNeeded()
                hudPanel.setContentSize(hudHost.fittingSize)
                capture(to: "\(dir)/hud-\(mode).png", window: hudPanel)
            }
            hudPanel.orderOut(nil)

            print("SNAPSHOT done \(dir)")
            for window in NSApp.windows {
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet)
                }
            }
            NSApp.terminate(nil)
        }
    }

    private static func capture(to path: String, window: NSWindow?) {
        if NSApp.isHidden {
            NSApp.unhideWithoutActivation()
        }
        guard let window = window ?? NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }) else {
            print("SNAPSHOT no window for \(path)")
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        window.displayIfNeeded()

        try? FileManager.default.removeItem(atPath: path)
        if !screencaptureUnavailable {
            for attempt in 1...2 {
                let shot = Process()
                shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
                try? shot.run()
                shot.waitUntilExit()
                if FileManager.default.fileExists(atPath: path) {
                    print("SNAPSHOT \(path)")
                    return
                }
                if attempt == 2 {
                    screencaptureUnavailable = true
                } else {
                    Thread.sleep(forTimeInterval: 0.25)
                }
            }
        }

        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("SNAPSHOT failed for \(path)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("SNAPSHOT \(path) (fallback: no Screen Recording permission)")
        }
    }
}

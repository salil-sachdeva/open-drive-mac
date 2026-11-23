import AppKit
import SwiftUI

/// Manages the Spotlight-style floating search palette (`⌃⌥F`).
@MainActor
public final class PalettePanelController {
    private var panel: NSPanel?
    private weak var viewModel: OpenDriveAppViewModel?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    public init(viewModel: OpenDriveAppViewModel) {
        self.viewModel = viewModel
        installHotkeyMonitors()
    }

    public func togglePalette() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        showPalette()
    }

    public func showPalette() {
        guard let viewModel else { return }
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 580, height: 380),
                styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.standardWindowButton(.miniaturizeButton)?.isHidden = true
            p.standardWindowButton(.zoomButton)?.isHidden = true
            p.isFloatingPanel = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isMovableByWindowBackground = true
            p.contentView = NSHostingView(rootView: GlobalPaletteView(viewModel: viewModel) { [weak p] in
                p?.orderOut(nil)
            })
            self.panel = p
        }
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installHotkeyMonitors() {
        let flagsMask: NSEvent.ModifierFlags = [.control, .option]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods == flagsMask && event.charactersIgnoringModifiers?.lowercased() == "f" {
                Task { @MainActor in
                    guard self?.viewModel?.searchHotkeyEnabled == true else { return }
                    self?.togglePalette()
                }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods == flagsMask && event.charactersIgnoringModifiers?.lowercased() == "f" {
                Task { @MainActor in
                    guard self?.viewModel?.searchHotkeyEnabled == true else { return }
                    self?.togglePalette()
                }
                return nil
            }
            return event
        }
    }
}

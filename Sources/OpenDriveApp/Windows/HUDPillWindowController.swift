import AppKit
import SwiftUI

/// Manages the translucent non-activating floating HUD pill during active uploads or eject-guard warnings.
@MainActor
public final class HUDPillWindowController {
    private var panel: NSPanel?
    private weak var viewModel: OpenDriveAppViewModel?

    public init(viewModel: OpenDriveAppViewModel) {
        self.viewModel = viewModel
    }

    public func updateVisibility(hasActiveUploads: Bool, alertMessage: String?) {
        guard hasActiveUploads || alertMessage != nil else {
            panel?.orderOut(nil)
            return
        }
        guard let viewModel else { return }
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 68),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isFloatingPanel = true
            p.level = .statusBar
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: HUDPillView(viewModel: viewModel))
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                p.setFrameOrigin(NSPoint(x: visible.maxX - 340, y: visible.maxY - 88))
            }
            self.panel = p
        }
        panel?.orderFrontRegardless()
    }
}

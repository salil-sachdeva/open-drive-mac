import AppKit
import SwiftUI

extension View {
    /// Opens the window with nothing focused: no focus ring and no text
    /// cursor until the user clicks or presses Tab.
    func noInitialFocus() -> some View {
        background(WindowFocusResetHook())
    }

    /// Sizes a Form, List, or ScrollView to its content height up to `max` points.
    func fitsContent(max: CGFloat = 640) -> some View {
        modifier(FitsContentModifier(maxHeight: max))
    }
}

private struct FitsContentModifier: ViewModifier {
    var maxHeight: CGFloat
    @State private var measuredHeight: CGFloat?

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height.rounded(.up)
            } action: { _, newValue in
                if abs(newValue - (measuredHeight ?? 0)) >= 1 {
                    measuredHeight = newValue
                }
            }
            .frame(height: measuredHeight.map { min($0, maxHeight) })
            .scrollBounceBehavior(.basedOnSize)
    }
}

private struct WindowFocusResetHook: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe {
        Probe()
    }

    func updateNSView(_ probe: Probe, context: Context) {}

    final class Probe: NSView {
        private var reopened = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            NotificationCenter.default.removeObserver(self)
            clearFirstResponder(in: window)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleWillClose),
                name: NSWindow.willCloseNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleDidBecomeKey),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
        }

        @objc private func handleWillClose(_ note: Notification) {
            reopened = true
        }

        @objc private func handleDidBecomeKey(_ note: Notification) {
            guard reopened, let window else { return }
            reopened = false
            clearFirstResponder(in: window)
        }

        private func clearFirstResponder(in window: NSWindow) {
            DispatchQueue.main.async {
                window.makeFirstResponder(nil)
            }
        }
    }
}

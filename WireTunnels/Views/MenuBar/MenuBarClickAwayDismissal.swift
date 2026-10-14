import AppKit
import SwiftUI

/// Resolve the actual containing window, rather than guessing from app windows.
struct MenuBarClickAwayDismissal: NSViewRepresentable {
    func makeNSView(context: Context) -> AttachmentView { AttachmentView() }

    func updateNSView(_ nsView: AttachmentView, context: Context) { }

    static func dismantleNSView(_ nsView: AttachmentView, coordinator: ()) {
        nsView.detach()
    }

    final class AttachmentView: NSView {
        private var controller: MenuBarDismissalController?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let window else { return }
            controller = MenuBarDismissalController(window: window)
            controller?.start()
        }

        func detach() {
            controller?.stop()
            controller = nil
        }
    }
}

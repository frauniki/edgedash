import AppKit
import SwiftUI

/// Owns the borderless dashboard window. "Cover, don't fight": the window
/// hides whatever macOS drops on the EDGE desktop, sits above the menu bar,
/// and never becomes key so touch interaction can't steal the user's focus.
@MainActor public final class DashboardWindowController {
    private var window: NSWindow?
    private var isWindowedPreview = false

    public init() {}

    public var isVisible: Bool { window?.isVisible ?? false }

    /// Fullscreen takeover of the given screen.
    public func show(on screen: NSScreen, content: some View) {
        if isWindowedPreview {
            window?.close()
            window = nil
        }
        isWindowedPreview = false
        let window = window ?? makeWindow()
        window.setFrame(screen.frame, display: true)
        window.contentView = NSHostingView(rootView: AnyView(content))
        window.orderFrontRegardless()
        self.window = window
    }

    /// Debug mode (`--windowed`): a plain resizable window on any display so
    /// M1–M4 development doesn't require the EDGE at all.
    public func showWindowed(content: some View) {
        if !isWindowedPreview {
            window?.close()
            window = nil
        }
        isWindowedPreview = true
        let window = self.window ?? {
            let w = NSWindow(
                contentRect: NSRect(x: 200, y: 200, width: 1280, height: 360),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            w.title = "EdgeDash Preview"
            w.isReleasedWhenClosed = false
            return w
        }()
        window.contentView = NSHostingView(rootView: AnyView(content))
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    public func hide() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        // Above menu bar (24) and Dock (20); below system alerts. Shielding
        // level would block TCC prompts and Mission Control — never use it.
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        // Borderless windows refuse key status by default — exactly what we
        // want: touches must never steal focus from the frontmost app.
        return window
    }
}

import AppKit
import SwiftUI

struct WindowStyler: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.tabbingMode = .disallowed
            // Let the content view extend under the titlebar so the sidebar
            // and terminal paint continuously up to the top of the window.
            // Without this the titlebar floats above the sidebar with a
            // visible boundary, which is jarring when both are translucent.
            window.styleMask.insert(.fullSizeContentView)
            WindowAppearance.sync(window: window)
            context.coordinator.observe(window: window)
            // Intercept the close button to hide instead of close,
            // preserving terminal surfaces and running processes.
            context.coordinator.interceptClose(window: window)
        }
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}

    final class Coordinator: NSObject, NSWindowDelegate {
        nonisolated(unsafe) private var observer: Any?
        nonisolated(unsafe) weak var swiftuiDelegate: (any NSWindowDelegate)?

        @MainActor
        func observe(window: NSWindow) {
            // Re-apply on config change. AppKit also rebuilds the titlebar
            // subviews on becomeMain / fullscreen transitions, so we resync
            // there too via the delegate hooks below.
            observer = NotificationCenter.default.addObserver(
                forName: .orchardConfigDidChange,
                object: nil,
                queue: .main
            ) { [weak window] _ in
                guard let window else { return }
                MainActor.assumeIsolated { WindowAppearance.sync(window: window) }
            }
        }

        func windowDidBecomeMain(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            WindowAppearance.sync(window: window)
            swiftuiDelegate?.windowDidBecomeMain?(notification)
        }

        func windowDidEnterFullScreen(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            WindowAppearance.sync(window: window)
            swiftuiDelegate?.windowDidEnterFullScreen?(notification)
        }

        func windowDidExitFullScreen(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            WindowAppearance.sync(window: window)
            swiftuiDelegate?.windowDidExitFullScreen?(notification)
        }

        @MainActor
        func interceptClose(window: NSWindow) {
            swiftuiDelegate = window.delegate
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            // During app termination AppKit asks every window if it can close.
            // The "hide instead of close" trick is only for the user clicking
            // the red close button while the app keeps running — when we're
            // shutting down, let the window actually close so the process can
            // exit instead of leaving an invisible window holding the app open.
            if AppTerminationState.isTerminating { return true }
            sender.orderOut(nil)
            return false
        }

        /// Forward everything else to SwiftUI's delegate
        nonisolated override func responds(to aSelector: Selector!) -> Bool {
            if super.responds(to: aSelector) { return true }
            return swiftuiDelegate?.responds(to: aSelector) ?? false
        }

        nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if swiftuiDelegate?.responds(to: aSelector) == true { return swiftuiDelegate }
            return super.forwardingTarget(for: aSelector)
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

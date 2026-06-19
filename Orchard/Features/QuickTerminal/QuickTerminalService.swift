import AppKit
import Carbon
import SwiftUI

@MainActor
final class QuickTerminalService: NSObject {
    static let shared = QuickTerminalService()

    private(set) var panel: QuickTerminalPanel?
    var panelRef: QuickTerminalPanel? { panel }
    private var hostingView: NSHostingView<QuickTerminalView>?
    private(set) var isVisible = false
    var carbonHotKeyRef: EventHotKeyRef?
    var carbonEventHandler: EventHandlerRef?
    /// String form of the shortcut we currently have registered with Carbon,
    /// so `userDefaultsDidChange` can detect rebinds and re-register.
    var lastRegisteredShortcutID: String?
    /// Snapshot of `isEnabled` after the most recent reconcile. Used to detect
    /// flips when `UserDefaults.didChangeNotification` fires, since that
    /// notification doesn't tell us which key changed.
    private var lastKnownEnabled: Bool = Preferences.shared.quickTerminalEnabled
    /// The app that was frontmost just before we showed the quick terminal.
    /// Captured so we can re-activate it on hide if Orchard somehow took over —
    /// without this, dismissing the panel would leave focus on Orchard even
    /// though the user expected to return to whatever they were doing.
    private var previousFrontmostApp: NSRunningApplication?
    let splitState = QuickTerminalSplitState()
    var suppressAutoHide = false
    private var isEnabled: Bool {
        // Read directly from UserDefaults instead of Preferences.shared.
        // Preferences caches the value in a stored property that's only set on
        // init and via its own setter — Settings writes through @AppStorage,
        // which bypasses Preferences entirely. Reading defaults here keeps the
        // service in sync with whatever the toggle's current persisted value
        // actually is.
        UserDefaults.standard.object(forKey: Preferences.Keys.quickTerminalEnabled) as? Bool ?? true
    }

    override private init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(toggle), name: .toggleQuickTerminal, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(autoTilingDidChange),
            name: .autoTilingEnabledDidChange,
            object: nil
        )
        // Observe UserDefaults broadly so we hot-reload no matter who flips the
        // toggle. Settings uses @AppStorage which writes through UserDefaults
        // without going through Preferences.shared, so observing the
        // Preferences object would miss those writes. didChangeNotification
        // fires on any key change; we filter by snapshotting the value.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        // Re-apply the blur radius when Ghostty config changes so the visible
        // panel picks up Settings adjustments without needing to be re-shown.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reapplyBlur),
            name: .orchardConfigDidChange,
            object: nil
        )
        if isEnabled { registerHotKey() }
    }

    @objc
    private func reapplyBlur() {
        guard let panel, isVisible else { return }
        setWindowBackgroundBlur(panel, radius: Preferences.shared.windowBlurRadius)
    }

    @objc
    private func userDefaultsDidChange() {
        // Two unrelated keys we react to: the enable toggle and the hotkey
        // binding. Reconcile both each time since UserDefaults' change
        // notification doesn't tell us which key changed.
        let now = isEnabled
        if now != lastKnownEnabled {
            lastKnownEnabled = now
            if now {
                registerHotKey()
            } else {
                if isVisible { hide() }
                unregisterHotKey()
            }
        }
        // Re-register on hotkey-binding changes so a Settings → Keymaps
        // rebind takes effect immediately, not after restart.
        let currentBindingID = lastRegisteredShortcutID
        let newBindingID = HotkeyRegistry.selectedShortcut(for: .toggleQuickTerminal)?.id
        if now, currentBindingID != newBindingID {
            unregisterHotKey()
            registerHotKey()
        }
    }

    @objc
    private func autoTilingDidChange() {
        guard Preferences.shared.autoTilingEnabled else { return }
        splitState.splitRoot.rebalanced()
    }

    @objc
    func toggle() {
        guard isEnabled else {
            if isVisible { hide() }
            return
        }
        if isVisible { hide() } else { show() }
    }


    // MARK: - Show / Hide

    private func show() {
        let panel = makePanel()
        self.panel = panel
        guard let screen = NSScreen.main else { return }
        let sf = screen.visibleFrame
        let wFrac = Preferences.shared.quickTerminalWidthFraction
        let hFrac = Preferences.shared.quickTerminalHeightFraction
        let w = sf.width * wFrac, h = sf.height * hFrac
        panel.setFrame(NSRect(x: sf.minX + (sf.width - w) / 2, y: sf.minY + (sf.height - h) / 2, width: w, height: h), display: false)

        let view = QuickTerminalView(state: splitState)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hosting)
        hostingView = hosting

        // Capture the currently-frontmost app *before* showing so we can put
        // focus back on it when the panel hides. The `.nonactivatingPanel`
        // styleMask plus `canBecomeKey` lets the panel receive keyboard input
        // without activating Orchard — the same trick Spotlight and Ghostty's
        // own quick terminal use. We deliberately do NOT call NSApp.activate()
        // here; doing so would steal focus from whatever the user was just
        // working in.
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousFrontmostApp = frontmost
        }
        panel.makeKeyAndOrderFront(nil)
        // Apply the current blur radius (0 = no blur) for this panel session.
        setWindowBackgroundBlur(panel, radius: Preferences.shared.windowBlurRadius)
        if let focusedID = splitState.focusedPaneID {
            FocusRestoration.restoreFocus(to: focusedID, in: splitState.splitRoot, window: panel)
        }
        isVisible = true
    }

    /// Refocus a pane after a close — retries briefly to wait for the new view.
    func refocusPane(_ paneID: UUID) {
        guard let panel, isVisible else { return }
        FocusRestoration.restoreFocus(to: paneID, in: splitState.splitRoot, window: panel)
    }

    private func hide() {
        panel?.orderOut(nil)
        hostingView?.removeFromSuperview()
        hostingView = nil
        panel = nil
        isVisible = false
        // Belt-and-suspenders: if Orchard somehow ended up frontmost while the
        // panel was visible (e.g. the user clicked the dock icon, or another
        // code path called NSApp.activate), bounce focus back to whoever was
        // active before. Skips when Orchard wasn't frontmost to begin with —
        // i.e. the common case where .nonactivatingPanel kept us in the
        // background and there's nothing to restore.
        if let prev = previousFrontmostApp,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        {
            prev.activate()
        }
        previousFrontmostApp = nil
    }

    private func makePanel() -> QuickTerminalPanel {
        let p = QuickTerminalPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.contentView = NSView()
        return p
    }
}

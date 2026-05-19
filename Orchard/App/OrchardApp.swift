import AppKit
import SwiftUI

@main
struct OrchardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    var appDelegate
    @State
    private var appState = AppState()
    @State
    private var projectStore = ProjectStore()

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environment(appState)
                .environment(projectStore)
                .alert(
                    "Close running process?",
                    isPresented: Binding(
                        get: { appState.pendingClosePane != nil },
                        set: { if !$0 { appState.cancelPendingClosePane() } }
                    )
                ) {
                    Button("Cancel", role: .cancel) {
                        appState.cancelPendingClosePane()
                    }
                    Button("Close", role: .destructive) {
                        appState.confirmPendingClosePane()
                    }
                } message: {
                    Text("A process is still running in this pane. Close it anyway?")
                }
                .onAppear {
                    appDelegate.appState = appState
                    appDelegate.projectStore = projectStore
                    appDelegate.onTerminate = { [appState] in appState.saveWorkspaces() }
                    appDelegate.installResponders(appState: appState, projectStore: projectStore)
                }
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                // Replace SwiftUI's "New Window" with "Show Window", which
                // unhides the single Orchard window after the user clicked
                // the red close button. Without this, hiding the window
                // leaves no menu/keyboard way to bring it back - only the
                // dock icon — and even that depends on AppKit reopen
                // delegation routing back through SwiftUI's WindowGroup.
                Button("Show Window") {
                    if let window = appDelegate.mainWindow {
                        window.makeKeyAndOrderFront(nil)
                        NSApp.activate()
                    }
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .toolbar) {}

            // Menu-bar surface for the most-used bindable commands. Each item
            // uses `.keyboardShortcut` so the macOS menu bar shows the
            // current binding (Settings → Keymaps overrides aren't reflected
            // until app restart — same caveat as the rest of the app). The
            // KeyRouter local NSEvent monitor intercepts keyDown before
            // AppKit's performKeyEquivalent runs, so menu shortcuts route
            // through the responder pipeline rather than firing twice.
            CommandMenu("Diff") {
                MenuShortcutButton(.refreshDiff) {
                    NotificationCenter.default.post(name: .refreshDiff, object: nil)
                }
            }
            CommandGroup(after: .sidebar) {
                MenuShortcutButton(.toggleSidebar) {
                    appState.sidebarVisible.toggle()
                }
                MenuShortcutButton(.toggleCommandPalette) {
                    appState.isCommandPaletteVisible.toggle()
                }
            }
        }
    }
}

/// Renders an `AppCommand` as a menu Button with its current keybinding
/// pre-wired so the macOS menu bar shows `⌘R` (etc.) next to the title.
/// Commands without a default shortcut still render — they just have no
/// equivalent rendered in the menu.
private struct MenuShortcutButton: View {
    let command: AppCommand
    let action: () -> Void

    init(_ command: AppCommand, action: @escaping () -> Void) {
        self.command = command
        self.action = action
    }

    var body: some View {
        Button(command.title, action: action)
            .modifier(KeyboardShortcutModifier(command: command))
    }
}

private struct KeyboardShortcutModifier: ViewModifier {
    let command: AppCommand

    func body(content: Content) -> some View {
        if let shortcut = HotkeyRegistry.selectedShortcut(for: command),
           let key = shortcut.menuKeyEquivalent
        {
            content.keyboardShortcut(KeyboardShortcut(key, modifiers: shortcut.menuModifiers))
        } else {
            content
        }
    }
}

extension HotkeyShortcut {
    /// Maps the parsed keyCode back to a SwiftUI-renderable KeyEquivalent.
    /// Returns nil for keys we don't have a mapping for (rare — covers the
    /// keys used in default bindings).
    var menuKeyEquivalent: KeyEquivalent? {
        switch keyCode {
        case 36: .return
        case 48: .tab
        case 49: .space
        case 50: "`"
        case 24: "="
        case 27: "-"
        case 30: "]"
        case 33: "["
        case 41: ";"
        case 39: "'"
        case 42: "\\"
        case 43: ","
        case 44: "/"
        case 47: "."
        default:
            // Letters and digits round-trip through Self.charForCode.
            HotkeyShortcut.letterOrDigit(for: keyCode).map { KeyEquivalent($0) }
        }
    }

    var menuModifiers: EventModifiers {
        var out: EventModifiers = []
        if modifiers.contains(.command) { out.insert(.command) }
        if modifiers.contains(.control) { out.insert(.control) }
        if modifiers.contains(.shift) { out.insert(.shift) }
        if modifiers.contains(.option) { out.insert(.option) }
        return out
    }

    private static let codeToChar: [UInt16: Character] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g",
        6: "z", 7: "x", 8: "c", 9: "v", 11: "b",
        12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        25: "9", 26: "7", 28: "8", 29: "0",
        31: "o", 32: "u", 34: "i", 35: "p",
        37: "l", 38: "j", 40: "k",
        45: "n", 46: "m",
    ]

    static func letterOrDigit(for code: UInt16) -> Character? { codeToChar[code] }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?
    var appState: AppState?
    var projectStore: ProjectStore?
    var mainWindow: NSWindow?

    private var windowObserver: Any?
    private var activateObserver: Any?
    private var mainAppResponder: MainAppResponder?
    private var hasInstalledResponders = false

    func applicationDidFinishLaunching(_: Notification) {
        // Skip the heavy launch path when the app is hosting unit tests.
        // Without this, libghostty boots, the key router installs, etc. —
        // which times out the xctest runner that just wants to load our
        // module symbols. ProcessInfo.environment is the standard way to
        // detect xctest hosting (Xcode sets this env var).
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        _ = GhosttyApp.shared
        GhosttyApp.shared.installAppearanceTracking()
        _ = QuickTerminalService.shared
        KeyRouter.shared.install()
        // Dock-icon click on a hidden window: SwiftUI's
        // @NSApplicationDelegateAdaptor swallows applicationShouldHandleReopen,
        // and `didBecomeActiveNotification` doesn't always fire (e.g. when
        // the user clicks the dock icon while the app is already considered
        // active by AppKit). The NSWorkspace activation notification fires
        // reliably on every dock-click, filtered to our own bundle ID so
        // we don't react to other apps.
        activateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, bundleID == Bundle.main.bundleIdentifier else { return }
                self.reopenIfNeeded()
            }
        }

        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                if self.mainWindow == nil { self.mainWindow = window }
                self.mainAppResponder?.mainWindow = window
            }
        }
    }

    /// Called from OrchardApp.onAppear once the state objects exist. Registers
    /// responders in priority order: palette first, quick terminal second,
    /// main app last.
    func installResponders(appState: AppState, projectStore: ProjectStore) {
        guard !hasInstalledResponders else { return }
        hasInstalledResponders = true
        KeyRouter.shared.register(PaletteResponder(appState: appState))
        KeyRouter.shared.register(QuickTerminalResponder())
        let mainResponder = MainAppResponder(appState: appState, projectStore: projectStore)
        mainResponder.mainWindow = mainWindow
        mainAppResponder = mainResponder
        KeyRouter.shared.register(mainResponder)
        // Tab-cycle commit on Ctrl-release.
        KeyRouter.shared.registerFlagsHandler { [weak appState] event in
            guard let appState, appState.isTabCycling else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !flags.contains(.control),
               let projectID = appState.activeProjectID
            {
                appState.commitTabCycle(projectID: projectID)
            }
        }
    }

    func applicationWillTerminate(_: Notification) {
        onTerminate?()
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        let mainHasRunning =
            appState?.workspaces.values.contains { ws in
                ws.tabs.contains { tab in
                    tab.splitRoot.allPanes().contains { $0.nsView?.needsConfirmQuit() == true }
                }
            } ?? false
        let qtHasRunning = QuickTerminalService.shared.splitState.splitRoot
            .allPanes().contains { $0.nsView?.needsConfirmQuit() == true }
        let hasRunning = mainHasRunning || qtHasRunning

        if !hasRunning {
            AppTerminationState.isTerminating = true
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Quit Orchard?"
        alert.informativeText = "There are still processes running. Quit anyway?"
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            AppTerminationState.isTerminating = true
            return .terminateNow
        }
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    /// Bring our (possibly ordered-out) main window back. Robust to cases
    /// where `self.mainWindow` got stale: walks NSApp.windows for the first
    /// terminal-bearing window, falling back to the cached pointer.
    /// Bring our (possibly ordered-out) main window back. Robust to cases
    /// where `self.mainWindow` got stale: walks NSApp.windows for the first
    /// terminal-bearing window, falling back to the cached pointer.
    func reopenIfNeeded() {
        // If a non-panel window is already visible, nothing to do.
        if NSApp.windows.contains(where: { $0.isVisible && !($0 is NSPanel) }) {
            return
        }

        // Find the hidden main window. Don't filter on `canBecomeMain` — AppKit
        // reports that as false for ordered-out SwiftUI windows (which is
        // exactly the case we're handling). Filter on class instead: skip
        // panels (quick terminal, settings).
        let target = NSApp.windows.first { window in
            !window.isVisible && !(window is NSPanel)
        } ?? mainWindow

        guard let target else { return }
        target.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if mainWindow !== target {
            mainWindow = target
            mainAppResponder?.mainWindow = target
        }
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        return false
    }
}

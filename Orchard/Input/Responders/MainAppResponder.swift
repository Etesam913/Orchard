import AppKit

/// App-level hotkeys for the main window: split, close, focus, resize, tab
/// cycling, project navigation, new tab, new project, Cmd+1-9 tab selection,
/// etc. Runs after the palette responder.
@MainActor
final class MainAppResponder: KeyResponder {
    private let appState: AppState
    private let projectStore: ProjectStore
    weak var mainWindow: NSWindow?


    init(appState: AppState, projectStore: ProjectStore) {
        self.appState = appState
        self.projectStore = projectStore
    }

    func handle(_ event: NSEvent) -> KeyDisposition {
        // Hotkey picker in Settings captures keystrokes — pass through so the
        // user's next keypress reaches the picker instead of triggering actions.
        if HotkeyCaptureState.shared.isCapturing { return .passThrough }

        // When the command palette is visible, let SwiftUI's TextField /
        // onKeyPress handlers own the keyboard. Otherwise typing "New Tab"
        // into the palette would fire Cmd+T's New Tab action.
        if appState.isCommandPaletteVisible { return .passThrough }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if HotkeyRegistry.matches(event, command: .recentTab) {
            guard let projectID = appState.activeProjectID else { return .passThrough }
            appState.cycleRecentTab(projectID: projectID)
            return .handled
        }

        // Block Cmd+N from opening a second window.
        if flags == .command, (event.charactersIgnoringModifiers ?? "").lowercased() == "n" {
            mainWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return .handled
        }

        if HotkeyRegistry.matches(event, command: .newTab) {
            guard let projectID = appState.activeProjectID else { return .passThrough }
            appState.createTab(projectID: projectID, projects: projectStore.projects)
            return .handled
        }

        if HotkeyRegistry.matches(event, command: .closePane) {
            guard let projectID = appState.activeProjectID,
                  let pane = appState.focusedPane(for: projectID)
            else { return .passThrough }
            appState.requestClosePane(pane.id, projectID: projectID)
            return .handled
        }

        if HotkeyRegistry.matches(event, command: .splitRight) {
            guard let projectID = appState.activeProjectID else { return .passThrough }
            appState.splitPane(direction: .horizontal, projectID: projectID)
            return .handled
        }

        if HotkeyRegistry.matches(event, command: .splitDown) {
            guard let projectID = appState.activeProjectID else { return .passThrough }
            appState.splitPane(direction: .vertical, projectID: projectID)
            return .handled
        }

        if HotkeyRegistry.matches(event, command: .zoomPane) {
            guard let projectID = appState.activeProjectID else { return .passThrough }
            appState.toggleZoom(projectID: projectID)
            return .handled
        }

        if HotkeyRegistry.matches(event, command: .toggleSidebar) {
            appState.sidebarVisible.toggle()
            return .handled
        }

        if HotkeyRegistry.matches(event, command: .toggleDiffSidebar) {
            NotificationCenter.default.post(name: .toggleDiffSidebar, object: nil)
            return .handled
        }

        if HotkeyRegistry.matches(event, command: .nextProject) {
            appState.selectNextProject(projects: projectStore.projects)
            return .handled
        }
        if HotkeyRegistry.matches(event, command: .previousProject) {
            appState.selectPreviousProject(projects: projectStore.projects)
            return .handled
        }
        if HotkeyRegistry.matches(event, command: .nextTab) {
            appState.selectGlobalTab(.next, projects: projectStore.projects)
            return .handled
        }
        if HotkeyRegistry.matches(event, command: .previousTab) {
            appState.selectGlobalTab(.previous, projects: projectStore.projects)
            return .handled
        }

        if let dir = PaneCommandRouting.focusDirection(for: event) {
            guard let projectID = appState.activeProjectID else { return .passThrough }
            appState.focusPaneInDirection(dir, projectID: projectID)
            return .handled
        }

        if let dir = PaneCommandRouting.resizeDirection(for: event) {
            guard let projectID = appState.activeProjectID else { return .passThrough }
            appState.resizePane(dir, projectID: projectID)
            return .handled
        }

        if HotkeyRegistry.matches(event, command: .closeWindow) {
            mainWindow?.orderOut(nil)
            return .handled
        }

        if HotkeyRegistry.matches(event, command: .openProject) {
            _ = appState.openProject(store: projectStore)
            return .handled
        }

        if HotkeyRegistry.matches(event, command: .reloadGhosttyConfig) {
            GhosttyApp.shared.reloadAndReport()
            return .handled
        }

        if HotkeyRegistry.matches(event, command: .refreshDiff) {
            NotificationCenter.default.post(name: .refreshDiff, object: nil)
            return .handled
        }

        if HotkeyRegistry.matches(event, command: .focusDiffSearch) {
            guard appState.activeProjectID != nil else { return .passThrough }
            // A terminal surface owns Cmd+F (Ghostty has its own find), so let
            // the event pass through when the focus is in a terminal pane.
            let responder = (event.window ?? mainWindow)?.firstResponder
            if responder is GhosttyTerminalNSView { return .passThrough }
            NotificationCenter.default.post(name: .focusDiffSearch, object: nil)
            return .handled
        }

        // Cmd+1-9 tab selection. Must check after the configurable hotkeys
        // so user bindings take precedence over digits.
        if flags == .command {
            let key = (event.charactersIgnoringModifiers ?? "").lowercased()
            if let idx = Int(key), (1 ... 9).contains(idx),
               let projectID = appState.activeProjectID
            {
                appState.selectTabByIndex(idx - 1, projectID: projectID)
                return .handled
            }
        }

        return .passThrough
    }
}

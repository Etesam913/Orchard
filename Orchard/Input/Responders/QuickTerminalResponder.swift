import AppKit

/// Handles all hotkeys while the quick terminal is visible. Registered before
/// the main-app responder so split/close/focus route to the quick terminal
/// instead of the main window when the panel is up.
@MainActor
final class QuickTerminalResponder: KeyResponder {
    func handle(_ event: NSEvent) -> KeyDisposition {
        let qt = QuickTerminalService.shared
        guard qt.isVisible else { return .passThrough }
        let state = qt.splitState

        // Quick-terminal toggle keystroke arrived while Orchard itself is
        // active. The same shortcut is also registered as a Carbon global
        // hot key (see QuickTerminalService.registerHotKey) for when other
        // apps are frontmost.
        if HotkeyRegistry.matches(event, command: .toggleQuickTerminal) {
            NotificationCenter.default.post(name: .toggleQuickTerminal, object: nil)
            return .handled
        }

        if HotkeyRegistry.matches(event, command: .splitRight) {
            guard let paneID = state.focusedPaneID else { return .passThrough }
            state.split(paneID: paneID, direction: .horizontal)
            return .handled
        }
        if HotkeyRegistry.matches(event, command: .splitDown) {
            guard let paneID = state.focusedPaneID else { return .passThrough }
            state.split(paneID: paneID, direction: .vertical)
            return .handled
        }
        if HotkeyRegistry.matches(event, command: .closePane) {
            guard let paneID = state.focusedPaneID else { return .passThrough }
            state.requestClosePane(paneID)
            return .handled
        }
        if HotkeyRegistry.matches(event, command: .zoomPane) {
            guard let paneID = state.focusedPaneID else { return .passThrough }
            state.tab.toggleZoom(paneID: paneID)
            return .handled
        }
        if let dir = PaneCommandRouting.focusDirection(for: event) {
            guard let focusedID = state.focusedPaneID else { return .passThrough }
            if let bestID = state.splitRoot.nearestPane(from: focusedID, direction: dir) {
                state.focusPane(bestID)
            }
            return .handled
        }
        if let dir = PaneCommandRouting.resizeDirection(for: event) {
            state.resize(dir)
            return .handled
        }

        return .passThrough
    }
}

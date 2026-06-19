import AppKit
import Foundation

/// Thin wrapper around a single `TerminalTab` that the quick terminal uses as
/// its split tree. Delegates split/resize/close to `TerminalTab` so the main
/// window and quick terminal share the same mutation logic.
@MainActor @Observable
final class QuickTerminalSplitState {
    var tab: TerminalTab
    var pendingClosePaneID: UUID?

    var splitRoot: SplitNode {
        get { tab.splitRoot }
        set { tab.splitRoot = newValue }
    }

    var focusedPaneID: UUID? {
        get { tab.focusedPaneID }
        set { tab.focusedPaneID = newValue }
    }

    init() {
        tab = TerminalTab(projectPath: NSHomeDirectory())
    }

    func focusPane(_ paneID: UUID) {
        tab.focusPane(paneID)
    }

    func requestClosePane(_ paneID: UUID) {
        let needs = tab.splitRoot.findPane(id: paneID)?.nsView?.needsConfirmQuit() ?? false
        if needs {
            pendingClosePaneID = paneID
            presentConfirmAlert()
            return
        }
        closePane(paneID)
    }

    func confirmPendingClose() {
        guard let id = pendingClosePaneID else { return }
        pendingClosePaneID = nil
        closePane(id)
    }

    func cancelPendingClose() {
        pendingClosePaneID = nil
    }

    private func presentConfirmAlert() {
        QuickTerminalService.shared.suppressAutoHide = true
        let alert = NSAlert()
        alert.messageText = "Close running process?"
        alert.informativeText = "A process is still running in this pane. Close it anyway?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            confirmPendingClose()
        } else {
            cancelPendingClose()
        }
        if let panel = QuickTerminalService.shared.panelRef {
            panel.makeKeyAndOrderFront(nil)
            if let focusedID = focusedPaneID,
               let view = tab.splitRoot.findPane(id: focusedID)?.nsView
            {
                panel.makeFirstResponder(view)
            }
        }
        DispatchQueue.main.async {
            QuickTerminalService.shared.suppressAutoHide = false
        }
    }

    func split(paneID: UUID, direction: SplitDirection) {
        tab.split(paneID: paneID, direction: direction)
    }

    func resize(_ direction: PaneFocusDirection, delta: CGFloat = 0.03) {
        tab.resize(direction, delta: delta)
    }

    func closePane(_ paneID: UUID) {
        switch tab.removePane(paneID) {
        case .onlyPaneLeft:
            // Replace the whole tab with a fresh one — the quick terminal should
            // always have at least one pane, but we fully reset so the prior
            // pane's surface is torn down (removePane already destroyed it).
            tab = TerminalTab(projectPath: NSHomeDirectory())
        case .removed,
             .notFound:
            break
        }
        if let newID = focusedPaneID {
            QuickTerminalService.shared.refocusPane(newID)
        }
    }
}

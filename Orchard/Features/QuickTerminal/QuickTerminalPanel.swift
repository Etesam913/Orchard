import AppKit

final class QuickTerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        // Don't auto-hide while a confirmation alert is pending or is being torn down.
        if QuickTerminalService.shared.suppressAutoHide { return }
        if QuickTerminalService.shared.splitState.pendingClosePaneID != nil { return }
        if QuickTerminalService.shared.isVisible {
            QuickTerminalService.shared.toggle()
        }
    }
}

import AppKit

/// Shared directional hotkey tables for the responder chain.
///
/// Both `MainAppResponder` (main window) and `QuickTerminalResponder` map the
/// same set of focus/resize commands to directions; centralizing the tables
/// here keeps the two responders in sync and removes the duplication they
/// previously each carried.
enum PaneCommandRouting {
    static let focusActions: [(AppCommand, PaneFocusDirection)] = [
        (.focusLeft, .left),
        (.focusDown, .down),
        (.focusUp, .up),
        (.focusRight, .right),
    ]

    static let resizeActions: [(AppCommand, PaneFocusDirection)] = [
        (.resizeLeft, .left),
        (.resizeDown, .down),
        (.resizeUp, .up),
        (.resizeRight, .right),
    ]

    /// Direction of the first focus command whose hotkey matches `event`, if any.
    static func focusDirection(for event: NSEvent) -> PaneFocusDirection? {
        focusActions.first { HotkeyRegistry.matches(event, command: $0.0) }?.1
    }

    /// Direction of the first resize command whose hotkey matches `event`, if any.
    static func resizeDirection(for event: NSEvent) -> PaneFocusDirection? {
        resizeActions.first { HotkeyRegistry.matches(event, command: $0.0) }?.1
    }
}

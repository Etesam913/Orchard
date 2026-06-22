import AppKit

/// Shared directional hotkey tables for the responder chain.
///
/// Centralizes the focus/resize command-to-direction mapping used by the main
/// responder.
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

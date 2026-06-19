import Foundation

/// Finite-state machine for Ctrl+Tab "cycle to recent tab" within a workspace.
///
/// While the modifier is held, `cycle(in:)` walks a recency-ordered snapshot of
/// the workspace's tabs (peeking each without recording history). Releasing the
/// modifier calls `commit()`, which returns the landed-on tab and resets state.
/// Extracted from `AppState` so the transient cycling state doesn't live
/// alongside the persistent app state.
@MainActor
final class TabCycleController {
    private var order: [UUID] = []
    private var index = 0

    /// True while a cycle is in progress (between the first `cycle` and `commit`).
    var isCycling: Bool { !order.isEmpty }

    /// Advance to the next tab in recency order. Seeds the cycle from the
    /// workspace's current recency order on the first step.
    func cycle(in workspace: Workspace) {
        if order.isEmpty {
            order = workspace.recencyOrder()
            index = 0
        }
        guard order.count > 1 else { return }
        index = (index + 1) % order.count
        workspace.peekTab(order[index])
    }

    /// End the cycle, returning the tab the user landed on (or nil if no cycle
    /// was active). Always resets the controller to idle.
    func commit() -> UUID? {
        guard !order.isEmpty else { return nil }
        let selected = order[index]
        order = []
        index = 0
        return selected
    }
}

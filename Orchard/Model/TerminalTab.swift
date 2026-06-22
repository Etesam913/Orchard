import Foundation
import SwiftUI

/// A single tab — owns a split-pane tree.
@MainActor @Observable
final class TerminalTab: Identifiable {
    let id: UUID
    var customTitle: String?
    var splitRoot: SplitNode
    var focusedPaneID: UUID?
    /// When set, the split tree renders only this pane (zoom). The tree
    /// itself is untouched — clearing this restores the full layout.
    /// Transient: not persisted across launches.
    var zoomedPaneID: UUID?
    /// Most-recent-first stack of previously focused pane IDs
    /// (excludes the currently focused pane).
    @ObservationIgnored
    var paneFocusHistory = RecencyStack<UUID>(limit: 20)

    /// Record a focus change, pushing the previous pane onto history.
    func focusPane(_ paneID: UUID) {
        guard paneID != focusedPaneID else { return }
        if let current = focusedPaneID { paneFocusHistory.push(current) }
        paneFocusHistory.remove(paneID)
        focusedPaneID = paneID
    }

    /// Pick the next focus target after a pane is removed from the tree.
    /// Walks the history stack (skipping panes no longer in the tree), then
    /// falls back to the first pane in tree order.
    func nextFocusAfterClose() -> UUID? {
        let valid = Set(splitRoot.allPanes().map(\.id))
        paneFocusHistory.prune(keeping: valid)
        if let recent = paneFocusHistory.popValid(in: valid) { return recent }
        return splitRoot.allPanes().first?.id
    }

    var title: String {
        if let customTitle { return customTitle }
        let panes = splitRoot.allPanes()
        if panes.isEmpty { return "Terminal" }
        return panes.map(\.title).joined(separator: " | ")
    }

    var autoTitle: String {
        let panes = splitRoot.allPanes()
        if panes.isEmpty { return "Terminal" }
        return panes.map(\.sidebarSegmentTitle).joined(separator: " | ")
    }

    var sidebarTitle: String { customTitle ?? autoTitle }

    var isAssistantQueryRunning: Bool {
        splitRoot.allPanes().contains { $0.isAssistantQueryRunning }
    }

    var focusedPane: Pane? {
        guard let focusedPaneID else { return nil }
        return splitRoot.findPane(id: focusedPaneID)
    }

    init(projectPath: String) {
        id = UUID()
        let pane = Pane(projectPath: projectPath)
        splitRoot = .pane(pane)
        focusedPaneID = pane.id
    }

    init(id: UUID, splitRoot: SplitNode, focusedPaneID: UUID?, customTitle: String? = nil) {
        self.id = id
        self.splitRoot = splitRoot
        self.focusedPaneID = focusedPaneID
        self.customTitle = customTitle
    }

    // MARK: - Split/resize/close operations

    // These live on TerminalTab so AppState can handle persistence after split
    // tree mutations.

    /// Toggle zoom for `paneID`. While zoomed, the tab renders only that pane;
    /// toggling off (or zooming a different pane) restores the full split view.
    func toggleZoom(paneID: UUID) {
        guard splitRoot.findPane(id: paneID) != nil else { return }
        if zoomedPaneID == paneID {
            zoomedPaneID = nil
        } else {
            zoomedPaneID = paneID
            focusPane(paneID)
        }
    }

    /// Split the focused pane (or a specific pane) in `direction`, placing the
    /// new pane in the `.second` position. Returns the new pane ID if created.
    @discardableResult
    func split(paneID: UUID, direction: SplitDirection) -> UUID? {
        let pane = splitRoot.findPane(id: paneID)
        let livePwd = pane?.nsView?.currentPwd
        let sourcePath = livePwd ?? pane?.projectPath ?? NSHomeDirectory()
        let (newRoot, newID) = splitRoot.splitting(
            paneID: paneID, direction: direction, position: .second, projectPath: sourcePath
        )
        splitRoot = newRoot
        // Splitting reveals a new pane — exit zoom so it's visible.
        zoomedPaneID = nil
        if let newID { focusPane(newID) }
        if Preferences.shared.autoTilingEnabled { splitRoot.rebalanced() }
        return newID
    }

    /// Adjust the nearest matching-axis split ratio around the focused pane.
    func resize(_ direction: PaneFocusDirection, delta: CGFloat = 0.03) {
        guard let paneID = focusedPaneID else { return }
        splitRoot = splitRoot.resizing(paneID: paneID, direction: direction, delta: delta)
    }

    /// Remove a pane from the tree. Returns `.onlyPaneLeft` if the caller should
    /// close the whole tab (the pane was the last one), otherwise `.removed`.
    /// The pane's surface is destroyed in both cases.
    @discardableResult
    func removePane(_ paneID: UUID) -> PaneRemovalResult {
        guard let pane = splitRoot.findPane(id: paneID) else { return .notFound }
        pane.destroySurface()
        let panes = splitRoot.allPanes()
        if panes.count <= 1 {
            return .onlyPaneLeft
        }
        guard let newRoot = splitRoot.removing(paneID: paneID) else { return .notFound }
        splitRoot = newRoot
        if zoomedPaneID == paneID { zoomedPaneID = nil }
        paneFocusHistory.remove(paneID)
        if focusedPaneID == paneID {
            focusedPaneID = nextFocusAfterClose()
        }
        if Preferences.shared.autoTilingEnabled { splitRoot.rebalanced() }
        return .removed
    }
}

enum PaneRemovalResult {
    case removed
    case onlyPaneLeft
    case notFound
}

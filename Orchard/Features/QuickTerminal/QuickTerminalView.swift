import SwiftUI

struct QuickTerminalView: View {
    static let projectID = UUID()
    @Bindable var state: QuickTerminalSplitState

    var body: some View {
        let renderedNode: SplitNode = {
            if let zoomID = state.tab.zoomedPaneID, let pane = state.splitRoot.findPane(id: zoomID) {
                return .pane(pane)
            }
            return state.splitRoot
        }()
        SplitTreeView(
            node: renderedNode,
            focusedPaneID: state.focusedPaneID,
            zoomedPaneID: state.tab.zoomedPaneID,
            isActiveProject: true,
            projectID: Self.projectID,
            onFocusPane: { state.focusPane($0) },
            onSplit: { paneID, dir in state.split(paneID: paneID, direction: dir) },
            onClosePane: { state.closePane($0) },
            onToggleZoom: { state.tab.toggleZoom(paneID: $0) }
        )
        .id(renderedNode.id)
        .background(OrchardTheme.bgWithOpacity)
        .overlay(alignment: .topTrailing) {
            if let zoomID = state.tab.zoomedPaneID {
                ZoomIndicator(onExit: { state.tab.toggleZoom(paneID: zoomID) })
                    .padding(8)
                    .transition(.opacity)
            }
        }
    }
}

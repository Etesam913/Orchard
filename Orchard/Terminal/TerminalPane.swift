import AppKit
import SwiftUI

struct TerminalPane: View {
    let pane: Pane
    let focused: Bool
    let isZoomed: Bool
    let onFocus: () -> Void
    let onProcessExit: () -> Void
    let onSplitRequest: (SplitDirection, SplitPosition) -> Void
    let onZoomRequest: () -> Void
    let onAssistantActivity: (String, UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if pane.searchState.isVisible {
                TerminalSearchBar(
                    searchState: pane.searchState,
                    onNavigateNext: { pane.nsView?.navigateSearch(direction: .next) },
                    onNavigatePrevious: { pane.nsView?.navigateSearch(direction: .previous) },
                    onClose: {
                        guard let view = pane.nsView else { return }
                        view.endSearch()
                        // Return focus to the terminal so typing resumes
                        // without requiring a click.
                        view.window?.makeFirstResponder(view)
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            TerminalSurface(
                pane: pane,
                focused: focused,
                isZoomed: isZoomed,
                onFocus: onFocus,
                onProcessExit: onProcessExit,
                onSplitRequest: onSplitRequest,
                onZoomRequest: onZoomRequest,
                onAssistantActivity: onAssistantActivity
            )
        }
    }
}

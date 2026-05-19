import SwiftUI

struct DiffSidebar: View {
    let projectPath: String
    let state: ProjectDiff

    var body: some View {
        // Anchor side-effects on a stable container. Modifiers on `Group`
        // fan out to each child, so an `.onAppear` there fires every time
        // the if/else branch swaps — which on an empty-diff commit produces
        // a perpetual load → swap → load loop.
        ZStack {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if state.diff.isEmpty, !state.isLoading {
            ContentUnavailableView("No Diff", systemImage: "doc.text.magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PierreDiffView(diff: state.diff, projectPath: projectPath)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

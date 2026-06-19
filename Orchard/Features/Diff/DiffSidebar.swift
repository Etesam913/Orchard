import SwiftUI

struct DiffSidebar: View {
    let projectPath: String
    let state: ProjectDiff
    var splitView: Bool = false
    var searchQuery: String = ""
    var searchToken: Int = 0
    var searchNextToken: Int = 0
    var onSearchResult: ((Int, Int) -> Void)? = nil

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
        if state.isLoading {
            ProgressView()
                .controlSize(.regular)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.diff.isEmpty {
            ContentUnavailableView("No Diff", systemImage: "doc.text.magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PierreDiffView(
                diff: state.diff,
                projectPath: projectPath,
                splitView: splitView,
                searchQuery: searchQuery,
                searchToken: searchToken,
                searchNextToken: searchNextToken,
                onSearchResult: onSearchResult
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

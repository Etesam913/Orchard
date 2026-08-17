import AppKit
import SwiftUI

struct MainWindow: View {
    @Environment(AppState.self)
    private var appState
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    @Environment(ProjectStore.self)
    private var projectStore
    @State
    private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State
    private var diffModel = ProjectDiffModel()
    @State
    private var isDiffSidebarVisible = true
    @State
    private var isDiffSidebarInitiallyLoaded = false
    @State
    private var isDiffSearchVisible = false
    @State
    private var diffSearchQuery = ""
    // Bumped (debounced) as the user types to re-run the highlight pass.
    @State
    private var diffSearchToken = 0
    // Bumped on every Enter to jump to the next match.
    @State
    private var diffSearchNextToken = 0
    // Pending debounce for the live search-as-you-type.
    @State
    private var diffSearchDebounce: Task<Void, Never>?
    // Search is per-project: stash each project's field visibility + query so
    // switching away clears the bar and switching back restores it.
    @State
    private var diffSearchStates: [Project.ID: DiffSearchState] = [:]
    // Match count and current (1-based) match reported back by the WebView.
    @State
    private var diffSearchMatchCount = 0
    @State
    private var diffSearchMatchIndex = 0
    // Bumped to (re)focus the search field — e.g. when Cmd+F is pressed while
    // the field is already on screen, where `onAppear` won't fire again.
    @State
    private var diffSearchFocusTrigger = 0
    // Survives toggle. HSplitView discards the divider position when the
    // sidebar view is removed and re-added, so without this the bar snaps
    // back to its `idealWidth` every time the user hides/shows it.
    @AppStorage("orchard.diffSidebar.width")
    private var diffSidebarWidth: Double = 425
    // Same story for the project (left) sidebar: NavigationSplitView resets
    // the column to its `idealWidth` whenever columnVisibility flips back
    // from .detailOnly to .automatic.
    @AppStorage("orchard.projectSidebar.width")
    private var projectSidebarWidth: Double = 180
    // Unified vs. side-by-side diff layout. Persisted so the choice sticks
    // across launches, like GitHub's split/unified preference.
    @AppStorage("orchard.diffSplitView")
    private var isDiffSplitView = false

    // Shared so the toolbar search field matches the diff panel's minimum
    // width exactly.
    private let diffSidebarMinWidth: CGFloat = 480
    private let diffSplitSidebarMinWidth: CGFloat = 440
    private let diffSidebarMaxWidth: CGFloat = 1200

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarContent()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ProjectSidebarWidthKey.self,
                            value: proxy.size.width
                        )
                    }
                )
                .onPreferenceChange(ProjectSidebarWidthKey.self) { width in
                    guard width > 1 else { return }
                    projectSidebarWidth = width
                }
                .navigationSplitViewColumnWidth(
                    min: 140,
                    ideal: projectSidebarWidth,
                    max: 280
                )
        } detail: {
            detailColumn
        }
        .background(WindowStyler())
        .overlay {
            if appState.isCommandPaletteVisible {
                CommandPaletteOverlay()
            }
        }

        .task {
            guard !appState.hasRestoredSelection else { return }
            appState.restoreSelection(projects: projectStore.projects)
        }
        .onChange(of: appState.sidebarVisible) { _, visible in
            columnVisibility = visible ? .automatic : .detailOnly
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshDiff)) { _ in
            // Cmd+R / palette → drive the toolbar's refresh path so the user
            // sees the spinner appear, just like clicking the button.
            guard activeProject != nil else { return }
            diffModel.load(project: activeProject, revision: diffModel.state.revision)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleDiffSidebar)) { _ in
            toggleDiffSidebar()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusDiffSearch)) { _ in
            // Cmd+F: reveal the diff sidebar and the search field if needed,
            // then focus it. If it's already open, just re-focus.
            setDiffSidebarVisible(true)
            isDiffSearchVisible = true
            diffSearchFocusTrigger += 1
        }
        .onChange(of: diffSearchQuery) {
            // Search-as-you-type: re-run the highlight pass (and refresh the
            // match count) 200ms after the last keystroke.
            diffSearchDebounce?.cancel()
            diffSearchDebounce = Task {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                diffSearchToken += 1
            }
        }
        .onChange(of: activeProject?.id) { oldID, newID in
            // Stash the outgoing project's search state, then restore the
            // incoming one (or start blank for a project not searched yet).
            diffSearchDebounce?.cancel()
            if let oldID {
                diffSearchStates[oldID] = DiffSearchState(
                    isVisible: isDiffSearchVisible,
                    query: diffSearchQuery
                )
            }
            let restored = newID.flatMap { diffSearchStates[$0] } ?? DiffSearchState()
            isDiffSearchVisible = restored.isVisible
            diffSearchQuery = restored.query
            diffSearchMatchCount = 0
            diffSearchMatchIndex = 0
            // Apply (or clear) the restored query against the new diff. The
            // WebView also re-applies after its render completes, covering the
            // async diff load.
            diffSearchToken += 1
        }
        .onChange(of: appState.isCommandPaletteVisible) { _, visible in
            guard !visible else { return }
            // Run a post-dismiss action if one was registered, otherwise return
            // focus to the active terminal pane so typing resumes immediately.
            if let action = appState.postPaletteAction {
                appState.postPaletteAction = nil
                DispatchQueue.main.async { action() }
            } else {
                DispatchQueue.main.async { appState.restoreFocusToActivePane() }
            }
        }
    }

    // Broken out of `body` so each piece type-checks on its own. SwiftUI's
    // `some View` inference times out when the whole detail column (workspace +
    // diff sidebar + toolbar) is a single expression.
    @ViewBuilder
    private var detailColumn: some View {
        let project = activeProject
        let diffState = diffModel.state
        HSplitView {
            workspaceColumn
            if isDiffSidebarVisible {
                diffSidebarColumn(project: project, diffState: diffState)
            }
        }
        .task(id: activeProject?.id) {
            diffModel.load(project: activeProject)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                if Task.isCancelled { break }
                await diffModel.refresh()
            }
        }
        .navigationTitle(activeProject?.name ?? "Orchard")
        .navigationSubtitle(activeTabTitle)
        .toolbar {
            detailToolbar(project: project, diffState: diffState)
        }
    }

    @ViewBuilder
    private var workspaceColumn: some View {
        ZStack {
            // The window's NSWindow.backgroundColor (set by WindowAppearance)
            // fills the detail column at the configured opacity. No need
            // to paint another tinted layer here; doing so stacks two
            // translucent fills and the detail reads as darker than the
            // strip around the sidebar.
            if let project = activeProjectWithWorkspace {
                if projectHasAnyTab(project) {
                    WorkspaceView(project: project)
                        .id(project.id)
                } else {
                    EmptyProjectView(project: project)
                        .id(project.id)
                }
            } else {
                WelcomeView()
            }
        }
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func diffSidebarColumn(project: Project?, diffState: ProjectDiff) -> some View {
        DiffSidebar(
            projectPath: project?.path ?? "",
            state: diffState,
            splitView: isDiffSplitView,
            searchQuery: diffSearchQuery,
            searchToken: diffSearchToken,
            searchNextToken: diffSearchNextToken,
            onSearchResult: { count, index in
                diffSearchMatchCount = count
                diffSearchMatchIndex = index
            }
        )
        // Before the sidebar has finished its first layout, pin it to the saved
        // width by collapsing min == max; afterwards relax to the draggable
        // range. Keeping a single `frame(minWidth:maxWidth:)` overload across
        // both states avoids a view-identity change that would reload the diff
        // WebView.
        .frame(
            minWidth: sidebarWidthLimit ?? activeDiffSidebarMinWidth,
            maxWidth: sidebarWidthLimit ?? diffSidebarMaxWidth
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: DiffSidebarWidthKey.self,
                    value: proxy.size.width
                )
            }
        )
        .onPreferenceChange(DiffSidebarWidthKey.self) { width in
            // Ignore the transient 0 frame during teardown so we
            // don't overwrite the last real width with garbage.
            guard isDiffSidebarVisible else { return }
            guard width >= activeDiffSidebarMinWidth, width <= diffSidebarMaxWidth else { return }
            diffSidebarWidth = width
        }
        .onAppear {
            DispatchQueue.main.async {
                isDiffSidebarInitiallyLoaded = true
            }
        }
    }

    @ToolbarContentBuilder
    private func detailToolbar(project: Project?, diffState: ProjectDiff) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if isDiffSidebarVisible, !diffState.isLoading {
                if isDiffSearchVisible {
                    DiffSearchField(
                        query: $diffSearchQuery,
                        matchCount: diffSearchMatchCount,
                        matchIndex: diffSearchMatchIndex,
                        // Track the diff panel's live width so the two
                        // line up no matter how the divider is dragged.
                        width: resolvedDiffSidebarWidth,
                        focusTrigger: diffSearchFocusTrigger,
                        onSubmit: { diffSearchNextToken += 1 },
                        onClose: { closeDiffSearch() }
                    )
                } else {
                    DiffStatsToolbarLabel(stats: diffState.stats)
                    Button {
                        diffModel.load(project: project, revision: diffState.revision)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(project == nil)
                    .help("Refresh diff")
                    Button {
                        isDiffSearchVisible = true
                        diffSearchFocusTrigger += 1
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .disabled(project == nil)
                    .help("Search diff")
                    Button {
                        isDiffSplitView.toggle()
                    } label: {
                        Image(systemName: isDiffSplitView ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                    }
                    .disabled(project == nil)
                    .help(isDiffSplitView ? "Switch to unified view" : "Switch to side-by-side view")
                }
            }
            Button {
                toggleDiffSidebar()
            } label: {
                Label(
                    isDiffSidebarVisible ? "Hide Changes" : "Show Changes",
                    systemImage: "sidebar.right"
                )
            }
            .help(isDiffSidebarVisible ? "Hide changes sidebar" : "Show changes sidebar")
        }
    }

    private func closeDiffSearch() {
        diffSearchDebounce?.cancel()
        isDiffSearchVisible = false
        diffSearchQuery = ""
        diffSearchMatchCount = 0
        diffSearchMatchIndex = 0
        // Bump the token with an empty query so the WebView clears highlights.
        diffSearchToken += 1
    }

    private func toggleDiffSidebar() {
        setDiffSidebarVisible(!isDiffSidebarVisible)
    }

    private func setDiffSidebarVisible(_ visible: Bool) {
        guard visible != isDiffSidebarVisible else { return }
        isDiffSidebarVisible = visible
        if !visible {
            isDiffSidebarInitiallyLoaded = false
        }
    }

    private var activeDiffSidebarMinWidth: CGFloat {
        isDiffSplitView ? diffSplitSidebarMinWidth : diffSidebarMinWidth
    }

    private var resolvedDiffSidebarWidth: CGFloat {
        min(max(CGFloat(diffSidebarWidth), activeDiffSidebarMinWidth), diffSidebarMaxWidth)
    }

    private var sidebarWidthLimit: CGFloat? {
        isDiffSidebarInitiallyLoaded ? nil : resolvedDiffSidebarWidth
    }

    private var activeProject: Project? {
        guard let pid = appState.activeProjectID else { return nil }
        return projectStore.projects.first { $0.id == pid }
    }

    private var activeProjectWithWorkspace: Project? {
        guard let project = activeProject, appState.workspaces[project.id] != nil else { return nil }
        return project
    }

    private func projectHasAnyTab(_ project: Project) -> Bool {
        !(appState.workspaces[project.id]?.tabs.isEmpty ?? true)
    }

    private var activeTabTitle: String {
        guard let project = activeProject else { return "" }
        return project.path
    }
}

struct WorkspaceView: View {
    let project: Project
    @Environment(AppState.self)
    private var appState

    var body: some View {
        if let ws = appState.workspaces[project.id], let tab = ws.activeTab {
            let renderedNode: SplitNode = {
                if let zoomID = tab.zoomedPaneID, let pane = tab.splitRoot.findPane(id: zoomID) {
                    return .pane(pane)
                }
                return tab.splitRoot
            }()
            SplitTreeView(
                node: renderedNode,
                focusedPaneID: tab.focusedPaneID,
                zoomedPaneID: tab.zoomedPaneID,
                isActiveProject: true,
                projectID: project.id,
                onFocusPane: { appState.focusPane($0, projectID: project.id) },
                onSplit: { paneID, dir in
                    tab.split(paneID: paneID, direction: dir)
                    appState.saveWorkspaces()
                },
                onClosePane: { appState.requestClosePane($0, projectID: project.id) },
                onToggleZoom: { tab.toggleZoom(paneID: $0) }
            )
            .id(renderedNode.id)
            .overlay(alignment: .topTrailing) {
                if tab.zoomedPaneID != nil {
                    ZoomIndicator(onExit: { appState.toggleZoom(projectID: project.id) })
                        .padding(8)
                        .transition(.opacity)
                }
            }
        }
    }
}

private struct DiffSidebarWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ProjectSidebarWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

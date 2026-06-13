import AppKit
import SwiftUI

struct MainWindow: View {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore
    @State
    private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State
    private var diffModel = ProjectDiffModel()
    @State
    private var isDiffSidebarVisible = true
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

    // Shared so the toolbar search field matches the diff panel's minimum
    // width exactly.
    private let diffSidebarMinWidth: CGFloat = 480

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
            let project = activeProject
            let diffState = diffModel.state
            HSplitView {
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

                if isDiffSidebarVisible {
                    DiffSidebar(
                        projectPath: project?.path ?? "",
                        state: diffState,
                        searchQuery: diffSearchQuery,
                        searchToken: diffSearchToken,
                        searchNextToken: diffSearchNextToken,
                        onSearchResult: { count, index in
                            diffSearchMatchCount = count
                            diffSearchMatchIndex = index
                        }
                    )
                    .frame(minWidth: diffSidebarMinWidth, idealWidth: diffSidebarWidth, maxWidth: 1200)
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
                        guard width > 1 else { return }
                        diffSidebarWidth = width
                    }
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
                ToolbarItemGroup(placement: .primaryAction) {
                    if isDiffSidebarVisible, !diffState.isLoading {
                        if isDiffSearchVisible {
                            DiffSearchField(
                                query: $diffSearchQuery,
                                matchCount: diffSearchMatchCount,
                                matchIndex: diffSearchMatchIndex,
                                // Track the diff panel's live width so the two
                                // line up no matter how the divider is dragged.
                                width: CGFloat(diffSidebarWidth),
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
                        }
                    }
                    Button {
                        isDiffSidebarVisible.toggle()
                    } label: {
                        Label(
                            isDiffSidebarVisible ? "Hide Changes" : "Show Changes",
                            systemImage: "sidebar.right"
                        )
                    }
                    .help(isDiffSidebarVisible ? "Hide changes sidebar" : "Show changes sidebar")
                }
            }
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
            isDiffSidebarVisible.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusDiffSearch)) { _ in
            // Cmd+F: reveal the diff sidebar and the search field if needed,
            // then focus it. If it's already open, just re-focus.
            if !isDiffSidebarVisible { isDiffSidebarVisible = true }
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

    private func closeDiffSearch() {
        diffSearchDebounce?.cancel()
        isDiffSearchVisible = false
        diffSearchQuery = ""
        diffSearchMatchCount = 0
        diffSearchMatchIndex = 0
        // Bump the token with an empty query so the WebView clears highlights.
        diffSearchToken += 1
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

struct WelcomeView: View {
    private var shortcuts: [(AppCommand, String)] {
        [
            (.openProject, "Open a project"),
            (.toggleCommandPalette, "Command palette"),
            (.toggleSidebar, "Toggle sidebar"),
        ]
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 6) {
                Text("Orchard")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(OrchardTheme.fg)
                Text("No project selected")
                    .font(.system(size: 12))
                    .foregroundStyle(OrchardTheme.fgMuted)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(shortcuts, id: \.0) { action, label in
                    HStack(spacing: 10) {
                        Text(label)
                            .font(.system(size: 12))
                            .foregroundStyle(OrchardTheme.fgMuted)
                            .frame(width: 160, alignment: .leading)
                        Text(HotkeyRegistry.displayString(for: HotkeyRegistry.selectedShortcutString(for: action)))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(OrchardTheme.fgDim)
                    }
                }
            }
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct EmptyProjectView: View {
    let project: Project

    private var shortcuts: [(AppCommand, String)] {
        [
            (.newTab, "New tab"),
            (.openProject, "Open another project"),
            (.toggleCommandPalette, "Command palette"),
            (.toggleSidebar, "Toggle sidebar"),
        ]
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 6) {
                Text(project.name)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(OrchardTheme.fg)
                Text(project.path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(OrchardTheme.fgMuted)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(shortcuts, id: \.0) { action, label in
                    HStack(spacing: 10) {
                        Text(label)
                            .font(.system(size: 12))
                            .foregroundStyle(OrchardTheme.fgMuted)
                            .frame(width: 160, alignment: .leading)
                        Text(HotkeyRegistry.displayString(for: HotkeyRegistry.selectedShortcutString(for: action)))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(OrchardTheme.fgDim)
                    }
                }
            }
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
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

/// Small badge shown in the corner of a tab while one of its panes is zoomed.
/// Clicking it exits zoom and restores the full split layout.
struct ZoomIndicator: View {
    let onExit: () -> Void

    var body: some View {
        Button(action: onExit) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                Text("Zoomed")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(OrchardTheme.fg)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help("Exit zoom")
    }
}

private struct WindowStyler: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.tabbingMode = .disallowed
            // Let the content view extend under the titlebar so the sidebar
            // and terminal paint continuously up to the top of the window.
            // Without this the titlebar floats above the sidebar with a
            // visible boundary, which is jarring when both are translucent.
            window.styleMask.insert(.fullSizeContentView)
            WindowAppearance.sync(window: window)
            context.coordinator.observe(window: window)
            // Intercept the close button to hide instead of close,
            // preserving terminal surfaces and running processes.
            context.coordinator.interceptClose(window: window)
        }
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}

    final class Coordinator: NSObject, NSWindowDelegate {
        nonisolated(unsafe) private var observer: Any?
        nonisolated(unsafe) weak var swiftuiDelegate: (any NSWindowDelegate)?

        @MainActor
        func observe(window: NSWindow) {
            // Re-apply on config change. AppKit also rebuilds the titlebar
            // subviews on becomeMain / fullscreen transitions, so we resync
            // there too via the delegate hooks below.
            observer = NotificationCenter.default.addObserver(
                forName: .orchardConfigDidChange,
                object: nil,
                queue: .main
            ) { [weak window] _ in
                guard let window else { return }
                MainActor.assumeIsolated { WindowAppearance.sync(window: window) }
            }
        }

        func windowDidBecomeMain(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            WindowAppearance.sync(window: window)
            swiftuiDelegate?.windowDidBecomeMain?(notification)
        }

        func windowDidEnterFullScreen(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            WindowAppearance.sync(window: window)
            swiftuiDelegate?.windowDidEnterFullScreen?(notification)
        }

        func windowDidExitFullScreen(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            WindowAppearance.sync(window: window)
            swiftuiDelegate?.windowDidExitFullScreen?(notification)
        }

        @MainActor
        func interceptClose(window: NSWindow) {
            swiftuiDelegate = window.delegate
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            // During app termination AppKit asks every window if it can close.
            // The "hide instead of close" trick is only for the user clicking
            // the red close button while the app keeps running — when we're
            // shutting down, let the window actually close so the process can
            // exit instead of leaving an invisible window holding the app open.
            if AppTerminationState.isTerminating { return true }
            sender.orderOut(nil)
            return false
        }

        /// Forward everything else to SwiftUI's delegate
        nonisolated override func responds(to aSelector: Selector!) -> Bool {
            if super.responds(to: aSelector) { return true }
            return swiftuiDelegate?.responds(to: aSelector) ?? false
        }

        nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if swiftuiDelegate?.responds(to: aSelector) == true { return swiftuiDelegate }
            return super.forwardingTarget(for: aSelector)
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

private struct DiffSidebarWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Per-project snapshot of the diff search field, swapped in/out on project
/// switch so each project keeps its own search.
private struct DiffSearchState {
    var isVisible = false
    var query = ""
}

/// Toolbar search box that replaces the diff stats/refresh controls while
/// active. Enter scrolls the diff to the next match; Escape or the ✕ closes it.
private struct DiffSearchField: View {
    @Binding var query: String
    let matchCount: Int
    let matchIndex: Int
    let width: CGFloat
    let focusTrigger: Int
    let onSubmit: () -> Void
    let onClose: () -> Void

    private var countLabel: String? {
        guard !query.isEmpty else { return nil }
        return matchCount == 0 ? "No results" : "\(matchIndex)/\(matchCount)"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            // AppKit-backed: a SwiftUI TextField in an NSToolbar can't reliably
            // steal first-responder from the WebView, so focus silently fails.
            // This wrapper calls makeFirstResponder directly.
            FocusableSearchField(
                text: $query,
                focusTrigger: focusTrigger,
                onSubmit: onSubmit,
                onCancel: onClose
            )
            .frame(maxWidth: .infinity)
            if let countLabel {
                Text(countLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close search")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: width)
    }
}

/// A borderless NSTextField that can be programmatically focused. `focusTrigger`
/// is a monotonic counter; whenever it changes the field grabs first responder,
/// which is the only reliable way to focus a control living inside an NSToolbar.
private struct FocusableSearchField: NSViewRepresentable {
    @Binding var text: String
    var focusTrigger: Int
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = "Search diff"
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        guard context.coordinator.lastFocusTrigger != focusTrigger else { return }
        context.coordinator.lastFocusTrigger = focusTrigger
        // Defer: on first appearance the field isn't in a window yet.
        DispatchQueue.main.async {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusableSearchField
        // Start at Int.min so the first real trigger value always differs and
        // focuses on initial appearance.
        var lastFocusTrigger = Int.min

        init(_ parent: FocusableSearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

private struct DiffStatsToolbarLabel: View {
    let stats: ProjectDiffStats

    var body: some View {
        HStack(spacing: 8) {
            Text("+\(stats.additions)")
                .foregroundStyle(Color(nsColor: .systemGreen))
            Text("-\(stats.deletions)")
                .foregroundStyle(Color(nsColor: .systemRed))
        }
        .font(.system(size: 13, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 12)
        .accessibilityLabel("\(stats.additions) additions, \(stats.deletions) deletions")
    }
}

private struct ProjectSidebarWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

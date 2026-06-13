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
    // Survives toggle. HSplitView discards the divider position when the
    // sidebar view is removed and re-added, so without this the bar snaps
    // back to its `idealWidth` every time the user hides/shows it.
    @AppStorage("orchard.diffSidebar.width")
    private var diffSidebarWidth: Double = 480
    // Same story for the project (left) sidebar: NavigationSplitView resets
    // the column to its `idealWidth` whenever columnVisibility flips back
    // from .detailOnly to .automatic.
    @AppStorage("orchard.projectSidebar.width")
    private var projectSidebarWidth: Double = 180

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
                        state: diffState
                    )
                    .frame(minWidth: 280, idealWidth: diffSidebarWidth, maxWidth: 1200)
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
                    if isDiffSidebarVisible {
                        Text("Changes")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 16)
                        Button {
                            diffModel.load(project: project, revision: diffState.revision)
                        } label: {
                            if diffState.isLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(project == nil || diffState.isLoading)
                        .help("Refresh diff")
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

private struct ProjectSidebarWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

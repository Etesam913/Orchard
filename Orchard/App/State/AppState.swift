import AppKit
import Foundation

/// Central observable store for the main window: the active project, every
/// project's `Workspace`, and assorted UI flags. Behavior is organized into
/// focused extensions — see `AppState+Projects`, `AppState+Tabs`, and
/// `AppState+Panes`.
@MainActor @Observable
final class AppState {
    var activeProjectID: UUID? {
        didSet { Preferences.shared.activeProjectID = activeProjectID }
    }

    var workspaces: [UUID: Workspace] = [:]
    var sidebarVisible = true
    var pendingClosePane: PendingClosePane?
    var isCommandPaletteVisible = false
    var postPaletteAction: (() -> Void)?
    var renamingTabID: UUID?
    var renamingProjectID: UUID?
    /// Set once on first restore. Settable from `AppState+Projects`, so internal.
    var hasRestoredSelection = false

    /// Most-recent-first stack of project IDs. Persisted to UserDefaults.
    /// Read/written by `AppState+Projects`, so not file-private.
    @ObservationIgnored
    var projectRecency = RecencyStack<UUID>(limit: 50)
    let recencyKey = "orchard.projectRecency"

    struct PendingClosePane: Equatable {
        let paneID: UUID
        let projectID: UUID
    }

    /// Transient Ctrl+Tab cycling state. See `TabCycleController`.
    @ObservationIgnored
    let tabCycle = TabCycleController()
    var isTabCycling: Bool { tabCycle.isCycling }

    let workspaceStore: WorkspaceStore
    @ObservationIgnored
    private var autoTileObserver: Any?

    init(workspaceStore: WorkspaceStore = WorkspaceStore()) {
        self.workspaceStore = workspaceStore
        autoTileObserver = NotificationCenter.default.addObserver(
            forName: .autoTilingEnabledDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebalanceAllWorkspacesIfEnabled() }
        }
        let restored = (UserDefaults.standard.stringArray(forKey: recencyKey) ?? [])
            .compactMap { UUID(uuidString: $0) }
        projectRecency = RecencyStack<UUID>(limit: 50, items: restored)
    }

    private func rebalanceAllWorkspacesIfEnabled() {
        guard Preferences.shared.autoTilingEnabled else { return }
        for ws in workspaces.values {
            for tab in ws.tabs {
                tab.splitRoot.rebalanced()
            }
        }
        saveWorkspaces()
    }

    func saveWorkspaces() {
        workspaceStore.save(WorkspaceSerializer.snapshot(workspaces))
    }

    // MARK: - Focus

    func restoreFocusToActivePane() {
        guard let projectID = activeProjectID,
              let tab = workspaces[projectID]?.activeTab,
              let paneID = tab.focusedPaneID
        else { return }
        FocusRestoration.restoreFocus(
            to: paneID,
            in: tab.splitRoot,
            window: NSApp.keyWindow ?? NSApp.mainWindow
        )
    }

    // MARK: - Workspace lookup

    func ensureWorkspace(projectID: UUID, path: String) {
        if workspaces[projectID] == nil {
            workspaces[projectID] = Workspace(projectID: projectID, projectPath: path)
        }
    }

    func ensureWorkspace(projectID: UUID, projects: [Project]) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        ensureWorkspace(projectID: projectID, path: project.path)
    }
}

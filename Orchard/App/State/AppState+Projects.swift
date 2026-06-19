import AppKit
import Foundation

// MARK: - Projects: selection, recency, restore, navigation

extension AppState {
    // MARK: Recency

    func recordProjectVisit(_ projectID: UUID) {
        projectRecency.push(projectID)
        UserDefaults.standard.set(projectRecency.items.map(\.uuidString), forKey: recencyKey)
    }

    /// Recently-visited projects, filtered to only those still present in the store.
    func recentProjects(from projects: [Project], limit: Int = 5) -> [Project] {
        let valid = Set(projects.map(\.id))
        let byID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        return projectRecency.top(limit, in: valid).compactMap { byID[$0] }
    }

    // MARK: Restore

    func restoreSelection(projects: [Project]) {
        hasRestoredSelection = true
        let snapshots = workspaceStore.load()
        let valid = Set(projects.map(\.id))
        for ws in WorkspaceSerializer.restore(from: snapshots, validIDs: valid) {
            workspaces[ws.projectID] = ws
        }
        if let id = Preferences.shared.activeProjectID,
           projects.contains(where: { $0.id == id })
        {
            activeProjectID = id
            recordProjectVisit(id)
            ensureWorkspace(projectID: id, projects: projects)
        }
    }

    // MARK: Selection

    func selectProject(_ project: Project) {
        activeProjectID = project.id
        recordProjectVisit(project.id)
        ensureWorkspace(projectID: project.id, path: project.path)
    }

    /// Shows an open panel, adds the selected directory as a project, and selects it.
    /// Returns the new project if one was created, nil if cancelled.
    @discardableResult
    func openProject(store: ProjectStore) -> Project? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a project folder"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let project = Project(
            name: url.lastPathComponent,
            path: url.path(percentEncoded: false),
            sortOrder: store.projects.count
        )
        store.add(project)
        selectProject(project)
        return project
    }

    /// Update the active project's path to wherever the focused pane currently
    /// sits (via OSC 7 — `pane.nsView.currentPwd`). Useful when a project
    /// started in one directory but the user has settled into a subdirectory
    /// and wants new tabs / persisted state to start there.
    ///
    /// No-op when there's no active project or no resolvable pwd. We don't
    /// touch open panes or workspaces — those keep their current cwd; only
    /// future tabs created via `createTab(projectID:projects:)` (which reads
    /// `project.path`) will land in the new directory.
    func replaceProjectPathWithCurrentDir(projectStore: ProjectStore) {
        guard let projectID = activeProjectID,
              let pane = focusedPane(for: projectID),
              let pwd = pane.nsView?.currentPwd,
              !pwd.isEmpty
        else { return }
        projectStore.setPath(id: projectID, to: pwd)
    }

    func removeProject(_ projectID: UUID) {
        if let ws = workspaces[projectID] {
            for pane in ws.tabs.flatMap({ $0.splitRoot.allPanes() }) {
                pane.destroySurface()
            }
        }
        workspaces.removeValue(forKey: projectID)
        if activeProjectID == projectID { activeProjectID = nil }
        saveWorkspaces()
    }

    // MARK: Navigation

    func selectNextProject(projects: [Project]) {
        guard projects.count > 1, let current = activeProjectID,
              let i = projects.firstIndex(where: { $0.id == current })
        else { return }
        let project = projects[(i + 1) % projects.count]
        selectProject(project)
    }

    func selectPreviousProject(projects: [Project]) {
        guard projects.count > 1, let current = activeProjectID,
              let i = projects.firstIndex(where: { $0.id == current })
        else { return }
        let project = projects[(i - 1 + projects.count) % projects.count]
        selectProject(project)
    }
}

import Foundation

// MARK: - Tabs: lifecycle, selection, cycling

extension AppState {
    func createTab(projectID: UUID, projectPath: String) {
        guard let ws = workspaces[projectID] else { return }
        ws.createTab(projectPath: projectPath)
        saveWorkspaces()
    }

    /// Convenience overload: look up the project's canonical path from the
    /// given projects list so new tabs always land in the project directory,
    /// not whatever cwd the last pane drifted to.
    func createTab(projectID: UUID, projects: [Project]) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        createTab(projectID: projectID, projectPath: project.path)
    }

    func closeTab(_ tabID: UUID, projectID: UUID) {
        guard let ws = workspaces[projectID],
              let tab = ws.tabs.first(where: { $0.id == tabID })
        else { return }
        for pane in tab.splitRoot.allPanes() {
            pane.destroySurface()
        }
        ws.closeTab(tabID)
        saveWorkspaces()
    }

    func selectTab(_ tabID: UUID, projectID: UUID) {
        workspaces[projectID]?.selectTab(tabID)
    }

    func selectNextTab(projectID: UUID) {
        workspaces[projectID]?.selectNextTab()
    }

    func selectPreviousTab(projectID: UUID) {
        workspaces[projectID]?.selectPreviousTab()
    }

    func cycleRecentTab(projectID: UUID) {
        guard let ws = workspaces[projectID] else { return }
        tabCycle.cycle(in: ws)
    }

    func commitTabCycle(projectID: UUID) {
        guard let selectedID = tabCycle.commit() else { return }
        guard let ws = workspaces[projectID] else { return }
        ws.selectTab(selectedID)
        saveWorkspaces()
    }

    enum GlobalTabDirection { case next, previous }

    func selectGlobalTab(_ direction: GlobalTabDirection, projects: [Project]) {
        let allTabs = projects.flatMap { p in
            (workspaces[p.id]?.tabs ?? []).map { (p, $0) }
        }
        guard !allTabs.isEmpty else { return }

        let currentTabID = activeProjectID.flatMap { pid in workspaces[pid]?.activeTabID }
        let currentIndex =
            allTabs.firstIndex { $0.0.id == activeProjectID && $0.1.id == currentTabID } ?? 0
        let newIndex: Int =
            switch direction {
            case .next: (currentIndex + 1) % allTabs.count
            case .previous: (currentIndex - 1 + allTabs.count) % allTabs.count
            }
        let (project, tab) = allTabs[newIndex]

        activeProjectID = project.id
        ensureWorkspace(projectID: project.id, path: project.path)
        workspaces[project.id]?.selectTab(tab.id)
    }

    func selectTabByIndex(_ index: Int, projectID: UUID) {
        workspaces[projectID]?.selectTabByIndex(index)
    }
}

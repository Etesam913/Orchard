import AppKit

/// Palette source for action commands. Iterates `AppCommand.allCases` so the
/// palette, Settings, and keyboard bindings all read from the same list.
/// Titles come from `AppCommand.title` (sentence case); keybind overlays
/// come from `AppCommand.defaultShortcut` when the command is bindable.
@MainActor
struct CommandSource: PaletteSource {
    func items(query: String, context: PaletteContext) -> [PaletteItem] {
        allItems(context).compactMap { item in
            guard let score = fuzzyScore(query: query, target: item.title) else { return nil }
            return PaletteItem(
                id: item.id,
                title: item.title,
                subtitle: item.subtitle,
                category: item.category,
                keybind: item.keybind,
                score: score,
                action: item.action
            )
        }
    }

    func emptyItems(context: PaletteContext) -> [PaletteItem]? {
        allItems(context)
    }

    // MARK: - Composition

    private func allItems(_ ctx: PaletteContext) -> [PaletteItem] {
        AppCommand.allCases.compactMap { make(command: $0, ctx: ctx) }
    }

    /// Builds a PaletteItem for `command`, or returns nil when the command
    /// doesn't apply in the current context (e.g. tab/pane commands when no
    /// project is active, rename/remove when there's no current project).
    private func make(command: AppCommand, ctx: PaletteContext) -> PaletteItem? {
        let projectID = ctx.appState.activeProjectID
        let current = projectID.flatMap { id in ctx.projectStore.projects.first(where: { $0.id == id }) }

        let action: (() -> Void)?
        switch command {
        // Tabs / panes — require an active project.
        case .newTab:
            guard let projectID else { return nil }
            action = { ctx.appState.createTab(projectID: projectID, projects: ctx.projectStore.projects) }
        case .closePane:
            guard let projectID else { return nil }
            action = {
                if let pane = ctx.appState.focusedPane(for: projectID) {
                    ctx.appState.requestClosePane(pane.id, projectID: projectID)
                }
            }
        case .nextTab:
            action = { ctx.appState.selectGlobalTab(.next, projects: ctx.projectStore.projects) }
        case .previousTab:
            action = { ctx.appState.selectGlobalTab(.previous, projects: ctx.projectStore.projects) }
        case .recentTab:
            guard let projectID else { return nil }
            action = { ctx.appState.cycleRecentTab(projectID: projectID) }
        case .renameTab:
            guard let projectID,
                  let tab = ctx.appState.workspaces[projectID]?.activeTab
            else { return nil }
            let tabID = tab.id
            action = {
                ctx.appState.postPaletteAction = {
                    ctx.appState.sidebarVisible = true
                    ctx.appState.renamingTabID = tabID
                }
            }
        case .splitRight:
            guard let projectID else { return nil }
            action = { ctx.appState.splitPane(direction: .horizontal, projectID: projectID) }
        case .splitDown:
            guard let projectID else { return nil }
            action = { ctx.appState.splitPane(direction: .vertical, projectID: projectID) }
        case .zoomPane:
            guard let projectID else { return nil }
            action = { ctx.appState.toggleZoom(projectID: projectID) }
        case .focusLeft:
            guard let projectID else { return nil }
            action = { ctx.appState.focusPaneInDirection(.left, projectID: projectID) }
        case .focusRight:
            guard let projectID else { return nil }
            action = { ctx.appState.focusPaneInDirection(.right, projectID: projectID) }
        case .focusUp:
            guard let projectID else { return nil }
            action = { ctx.appState.focusPaneInDirection(.up, projectID: projectID) }
        case .focusDown:
            guard let projectID else { return nil }
            action = { ctx.appState.focusPaneInDirection(.down, projectID: projectID) }
        case .resizeLeft:
            guard let projectID else { return nil }
            action = { ctx.appState.resizePane(.left, projectID: projectID) }
        case .resizeRight:
            guard let projectID else { return nil }
            action = { ctx.appState.resizePane(.right, projectID: projectID) }
        case .resizeUp:
            guard let projectID else { return nil }
            action = { ctx.appState.resizePane(.up, projectID: projectID) }
        case .resizeDown:
            guard let projectID else { return nil }
            action = { ctx.appState.resizePane(.down, projectID: projectID) }
        // Projects.
        case .openProject:
            action = { _ = ctx.appState.openProject(store: ctx.projectStore) }
        case .renameProject:
            guard let current else { return nil }
            let projectID = current.id
            action = {
                ctx.appState.postPaletteAction = {
                    ctx.appState.sidebarVisible = true
                    ctx.appState.renamingProjectID = projectID
                }
            }
        case .removeProject:
            guard let projectID else { return nil }
            action = {
                ctx.appState.removeProject(projectID)
                ctx.projectStore.remove(id: projectID)
            }
        case .replaceProjectPathWithCurrentDir:
            // Only meaningful when there's an active project AND the focused
            // pane's pwd differs from the project's current path. Hiding the
            // entry otherwise keeps the palette uncluttered.
            guard let projectID,
                  let pane = ctx.appState.focusedPane(for: projectID),
                  let pwd = pane.nsView?.currentPwd, !pwd.isEmpty,
                  current?.path != pwd
            else { return nil }
            action = { ctx.appState.replaceProjectPathWithCurrentDir(projectStore: ctx.projectStore) }
        case .nextProject:
            action = { ctx.appState.selectNextProject(projects: ctx.projectStore.projects) }
        case .previousProject:
            action = { ctx.appState.selectPreviousProject(projects: ctx.projectStore.projects) }
        // Window.
        case .toggleSidebar:
            action = { ctx.appState.sidebarVisible.toggle() }
        case .toggleDiffSidebar:
            action = { NotificationCenter.default.post(name: .toggleDiffSidebar, object: nil) }
        case .closeWindow:
            action = { (NSApp.delegate as? AppDelegate)?.mainWindow?.orderOut(nil) }
        case .toggleCommandPalette:
            // No palette entry for opening the palette — by definition the
            // palette has to already be open to see it. The action still
            // needs to exist in AppCommand so Settings → Keymaps can show
            // and rebind its hotkey.
            return nil
        case .reloadGhosttyConfig:
            action = { GhosttyApp.shared.reloadAndReport() }
        case .refreshDiff:
            action = { NotificationCenter.default.post(name: .refreshDiff, object: nil) }
        case .focusDiffSearch:
            guard projectID != nil else { return nil }
            action = { NotificationCenter.default.post(name: .focusDiffSearch, object: nil) }
        }

        guard let action else { return nil }
        return PaletteItem(
            title: command.title,
            category: command.category.rawValue,
            keybind: keybindDisplay(command),
            score: 0,
            action: action
        )
    }

    private func keybindDisplay(_ command: AppCommand) -> String? {
        guard command.defaultShortcut != nil else { return nil }
        let raw = HotkeyRegistry.selectedShortcutString(for: command)
        let display = HotkeyRegistry.displayString(for: raw)
        return display == "Disabled" ? nil : display
    }
}

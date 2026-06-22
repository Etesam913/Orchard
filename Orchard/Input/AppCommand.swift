import Foundation

/// Single source of truth for every user-invokable action — both palette
/// commands and keyboard-bindable ones. Each case owns its sentence-cased
/// `title`, palette `category`, and (when bindable) a `defaultShortcut`.
/// Palette-only commands return nil for `defaultShortcut`. The raw value
/// doubles as the stable identifier used for `UserDefaults` persistence,
/// so renaming a case in code does NOT change a user's saved binding.
enum AppCommand: String, CaseIterable, Identifiable {
    // Tabs
    case newTab = "new_tab"
    case closePane = "close_pane"
    case renameTab = "rename_tab"
    // `next_global_tab` / `previous_global_tab` predate the consolidation;
    // keeping the raw values preserves user keybindings stored in defaults.
    case nextTab = "next_global_tab"
    case previousTab = "previous_global_tab"
    case recentTab = "recent_tab"
    // Panes
    case splitRight = "split_right"
    case splitDown = "split_down"
    case zoomPane = "zoom_pane"
    case focusLeft = "focus_pane_left"
    case focusRight = "focus_pane_right"
    case focusUp = "focus_pane_up"
    case focusDown = "focus_pane_down"
    case resizeLeft = "resize_pane_left"
    case resizeRight = "resize_pane_right"
    case resizeUp = "resize_pane_up"
    case resizeDown = "resize_pane_down"
    // Projects
    case openProject = "open_project"
    case renameProject = "rename_project"
    case removeProject = "remove_project"
    case replaceProjectPathWithCurrentDir = "replace_project_path_with_current_dir"
    case nextProject = "next_project"
    case previousProject = "previous_project"
    // Window
    case toggleSidebar = "toggle_sidebar"
    case toggleDiffSidebar = "toggle_diff_sidebar"
    case closeWindow = "close_window"
    case toggleCommandPalette = "toggle_command_palette"
    case reloadGhosttyConfig = "reload_ghostty_config"
    case refreshDiff = "refresh_diff"
    case focusDiffSearch = "focus_diff_search"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newTab: "New tab"
        case .closePane: "Close pane"
        case .renameTab: "Rename current tab"
        case .nextTab: "Next tab"
        case .previousTab: "Previous tab"
        case .recentTab: "Recent tab"
        case .splitRight: "Split right"
        case .splitDown: "Split down"
        case .zoomPane: "Zoom pane"
        case .focusLeft: "Focus left"
        case .focusRight: "Focus right"
        case .focusUp: "Focus up"
        case .focusDown: "Focus down"
        case .resizeLeft: "Resize pane left"
        case .resizeRight: "Resize pane right"
        case .resizeUp: "Resize pane up"
        case .resizeDown: "Resize pane down"
        case .openProject: "Open project"
        case .renameProject: "Rename current project"
        case .removeProject: "Remove current project"
        case .replaceProjectPathWithCurrentDir: "Replace project path with current directory"
        case .nextProject: "Next project"
        case .previousProject: "Previous project"
        case .toggleSidebar: "Toggle sidebar"
        case .toggleDiffSidebar: "Toggle diff sidebar"
        case .closeWindow: "Close window"
        case .toggleCommandPalette: "Command palette"
        case .reloadGhosttyConfig: "Reload Ghostty config"
        case .refreshDiff: "Refresh diff"
        case .focusDiffSearch: "Search diff"
        }
    }

    var category: Category {
        switch self {
        case .newTab,
             .closePane,
             .renameTab,
             .nextTab,
             .previousTab,
             .recentTab: .tabs
        case .splitRight,
             .splitDown,
             .zoomPane,
             .focusLeft,
             .focusRight,
             .focusUp,
             .focusDown,
             .resizeLeft,
             .resizeRight,
             .resizeUp,
             .resizeDown: .panes
        case .openProject,
             .renameProject,
             .removeProject,
             .replaceProjectPathWithCurrentDir,
             .nextProject,
             .previousProject: .projects
        case .toggleSidebar,
             .toggleDiffSidebar,
             .closeWindow,
             .toggleCommandPalette,
             .reloadGhosttyConfig,
             .refreshDiff,
             .focusDiffSearch: .window
        }
    }

    /// Default key binding. `nil` means the command is palette-only (no
    /// keyboard binding by default — and Settings → Keymaps will hide it
    /// from the bindable list).
    var defaultShortcut: String? {
        switch self {
        case .newTab: "cmd+t"
        case .closePane: "cmd+w"
        case .renameTab: nil
        case .nextTab: "ctrl+]"
        case .previousTab: "ctrl+["
        case .recentTab: "ctrl+tab"
        case .splitRight: "cmd+d"
        case .splitDown: "cmd+shift+d"
        case .zoomPane: "cmd+shift+return"
        case .focusLeft: "cmd+ctrl+h"
        case .focusRight: "cmd+ctrl+l"
        case .focusUp: "cmd+ctrl+k"
        case .focusDown: "cmd+ctrl+j"
        case .resizeLeft: "cmd+shift+h"
        case .resizeRight: "cmd+shift+l"
        case .resizeUp: "cmd+shift+k"
        case .resizeDown: "cmd+shift+j"
        case .openProject: "cmd+o"
        case .renameProject: nil
        case .removeProject: nil
        case .replaceProjectPathWithCurrentDir: nil
        case .nextProject: "cmd+]"
        case .previousProject: "cmd+["
        case .toggleSidebar: "cmd+b"
        case .toggleDiffSidebar: "cmd+opt+b"
        case .closeWindow: "cmd+shift+w"
        case .toggleCommandPalette: "cmd+p"
        case .reloadGhosttyConfig: "cmd+shift+,"
        case .refreshDiff: "cmd+r"
        case .focusDiffSearch: "cmd+f"
        }
    }

    /// Built-in extra bindings that always work alongside the primary
    /// shortcut (browser-style Cmd+Shift+[ / ] tab switching). Not shown or
    /// rebindable in Settings → Keymaps.
    var secondaryShortcuts: [String] {
        switch self {
        case .nextTab: ["cmd+shift+]"]
        case .previousTab: ["cmd+shift+["]
        default: []
        }
    }

    /// `UserDefaults` key for the user's override of the default shortcut.
    /// Stable: derived from the raw value, which never changes.
    var defaultsKey: String { "orchard.hotkey.\(rawValue)" }

    enum Category: String {
        case tabs = "Tabs"
        case panes = "Panes"
        case projects = "Projects"
        case window = "Window"
    }
}

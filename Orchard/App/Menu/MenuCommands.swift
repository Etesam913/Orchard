import AppKit
import SwiftUI

/// The app's menu-bar commands, extracted from `OrchardApp` so the Scene body
/// stays focused on window/state composition.
///
/// Each item uses `.keyboardShortcut` so the macOS menu bar shows the current
/// binding (Settings → Keymaps overrides aren't reflected until app restart —
/// same caveat as the rest of the app). The KeyRouter local NSEvent monitor
/// intercepts keyDown before AppKit's performKeyEquivalent runs, so menu
/// shortcuts route through the responder pipeline rather than firing twice.
struct AppMenuCommands: Commands {
    let appState: AppState
    /// Brings the (possibly hidden) main window back — wired up by `OrchardApp`.
    let showWindow: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // Replace SwiftUI's "New Window" with "Show Window", which
            // unhides the single Orchard window after the user clicked
            // the red close button. Without this, hiding the window
            // leaves no menu/keyboard way to bring it back - only the
            // dock icon — and even that depends on AppKit reopen
            // delegation routing back through SwiftUI's WindowGroup.
            Button("Show Window", action: showWindow)
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(replacing: .toolbar) {}

        CommandMenu("Diff") {
            MenuShortcutButton(.refreshDiff) {
                NotificationCenter.default.post(name: .refreshDiff, object: nil)
            }
        }
        CommandGroup(after: .sidebar) {
            MenuShortcutButton(.toggleSidebar) {
                appState.sidebarVisible.toggle()
            }
            MenuShortcutButton(.toggleCommandPalette) {
                appState.isCommandPaletteVisible.toggle()
            }
        }
    }
}

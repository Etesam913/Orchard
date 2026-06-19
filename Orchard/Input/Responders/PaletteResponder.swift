import AppKit

// The main `handleKeyEvent` used to be a 140-line cascade of if-statements in
// OrchardApp.swift. These responders own focused slices of that logic and get
// ordered by the KeyRouter so disposition is explicit instead of implicit.

/// Toggles the unified command palette on Cmd+P / Cmd+Shift+P. When the
/// palette is visible, passes other keys through to SwiftUI's own key
/// handlers (arrow navigation, escape, etc.).
@MainActor
final class PaletteResponder: KeyResponder {
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    func handle(_ event: NSEvent) -> KeyDisposition {
        if HotkeyRegistry.matches(event, command: .toggleCommandPalette) {
            appState.isCommandPaletteVisible.toggle()
            return .handled
        }
        // While the palette is visible, SwiftUI owns arrow / escape / etc.
        return .passThrough
    }
}

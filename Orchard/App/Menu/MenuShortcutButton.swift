import SwiftUI

/// Renders an `AppCommand` as a menu Button with its current keybinding
/// pre-wired so the macOS menu bar shows `⌘R` (etc.) next to the title.
/// Commands without a default shortcut still render — they just have no
/// equivalent rendered in the menu.
struct MenuShortcutButton: View {
    let command: AppCommand
    let action: () -> Void

    init(_ command: AppCommand, action: @escaping () -> Void) {
        self.command = command
        self.action = action
    }

    var body: some View {
        Button(command.title, action: action)
            .modifier(KeyboardShortcutModifier(command: command))
    }
}

struct KeyboardShortcutModifier: ViewModifier {
    let command: AppCommand

    func body(content: Content) -> some View {
        if let shortcut = HotkeyRegistry.selectedShortcut(for: command),
           let key = shortcut.menuKeyEquivalent
        {
            content.keyboardShortcut(KeyboardShortcut(key, modifiers: shortcut.menuModifiers))
        } else {
            content
        }
    }
}

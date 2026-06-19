import SwiftUI

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

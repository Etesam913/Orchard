import SwiftUI

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

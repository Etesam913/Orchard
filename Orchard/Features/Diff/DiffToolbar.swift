import AppKit
import SwiftUI

/// Per-project snapshot of the diff search field, swapped in/out on project
/// switch so each project keeps its own search.
struct DiffSearchState {
    var isVisible = false
    var query = ""
}

/// Toolbar search box that replaces the diff stats/refresh controls while
/// active. Enter scrolls the diff to the next match; Escape or the ✕ closes it.
struct DiffSearchField: View {
    @Binding var query: String
    let matchCount: Int
    let matchIndex: Int
    let width: CGFloat
    let focusTrigger: Int
    let onSubmit: () -> Void
    let onClose: () -> Void

    private var countLabel: String? {
        guard !query.isEmpty else { return nil }
        return matchCount == 0 ? "No results" : "\(matchIndex)/\(matchCount)"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            // AppKit-backed: a SwiftUI TextField in an NSToolbar can't reliably
            // steal first-responder from the WebView, so focus silently fails.
            // This wrapper calls makeFirstResponder directly.
            FocusableSearchField(
                text: $query,
                focusTrigger: focusTrigger,
                onSubmit: onSubmit,
                onCancel: onClose
            )
            .frame(maxWidth: .infinity)
            if let countLabel {
                Text(countLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close search")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: width)
    }
}

struct DiffStatsToolbarLabel: View {
    let stats: ProjectDiffStats

    var body: some View {
        HStack(spacing: 8) {
            Text("+\(stats.additions)")
                .foregroundStyle(Color(nsColor: .systemGreen))
            Text("-\(stats.deletions)")
                .foregroundStyle(Color(nsColor: .systemRed))
        }
        .font(.system(size: 13, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 12)
        .accessibilityLabel("\(stats.additions) additions, \(stats.deletions) deletions")
    }
}

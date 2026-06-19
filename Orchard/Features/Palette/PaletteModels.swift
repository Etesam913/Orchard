import Foundation

/// What the palette knows about the current session when asking sources for items.
/// Sources read this instead of poking globals directly, so they're easier to
/// reason about.
@MainActor
struct PaletteContext {
    let appState: AppState
    let projectStore: ProjectStore
}

/// A selectable palette item. Same shape as the old `CommandPaletteItem`
/// with an explicit `score` so the engine can rank-merge across sources.
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let category: String?
    let keybind: String?
    /// Lower is better. 0 = exact prefix match, ~5 = substring, ~40 = subsequence.
    let score: Int
    let action: () -> Void

    init(
        id: String? = nil,
        title: String,
        subtitle: String? = nil,
        category: String? = nil,
        keybind: String? = nil,
        score: Int = 1,
        action: @escaping () -> Void
    ) {
        self.id = id ?? "\(category ?? "")/\(title)"
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.keybind = keybind
        self.score = score
        self.action = action
    }
}

struct PaletteSection {
    let header: String?
    let items: [PaletteItem]
}

struct PaletteQuery {
    let raw: String
    var trimmed: String { raw.trimmingCharacters(in: .whitespaces) }
    var isEmpty: Bool { trimmed.isEmpty }
    var looksLikePath: Bool { trimmed.hasPrefix("/") || trimmed.hasPrefix("~") }
}

/// A pluggable source of palette items. Sources return scored items for a
/// query; the engine merges and ranks them.
@MainActor
protocol PaletteSource {
    /// Items for a non-empty, non-path query. Implementations return items
    /// with `score` populated (use `fuzzyScore`); non-matching items are omitted.
    func items(query: String, context: PaletteContext) -> [PaletteItem]

    /// Items shown when the input is empty. `nil` means "no empty-state items"
    /// (the engine skips this source's empty section).
    func emptyItems(context: PaletteContext) -> [PaletteItem]?
}

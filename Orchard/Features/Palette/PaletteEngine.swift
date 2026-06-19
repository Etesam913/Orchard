import Foundation

/// Composes sources, applies ranking, and returns the final sectioned list.
@MainActor
struct PaletteEngine {
    let sources: [PaletteSource]
    let context: PaletteContext
    /// Consulted only when the query is path-like. On path input, the engine
    /// replaces all sources' output with the path source's output.
    let pathSource: PaletteSource?

    func search(_ raw: String) -> [PaletteSection] {
        let q = PaletteQuery(raw: raw)

        // Path mode: short-circuit to only the path source.
        if q.looksLikePath, let pathSource {
            let items = pathSource.items(query: q.trimmed, context: context)
            return items.isEmpty ? [] : [PaletteSection(header: nil, items: items)]
        }

        if q.isEmpty {
            // Empty state: each source contributes a section. Sources set
            // their own categories (e.g. "Recent", "Tabs", "Panes") — we
            // just group by whatever they set.
            var sections: [PaletteSection] = []
            for source in sources {
                guard let items = source.emptyItems(context: context), !items.isEmpty else { continue }
                sections += groupByCategory(items)
            }
            return sections
        }

        // Active search: merge + rank to one flat list so the best match is
        // always on top regardless of which source produced it.
        var all: [PaletteItem] = []
        for source in sources {
            all += source.items(query: q.trimmed, context: context)
        }
        all.sort { $0.score < $1.score }
        return all.isEmpty ? [] : [PaletteSection(header: nil, items: all)]
    }

    private func groupByCategory(_ items: [PaletteItem]) -> [PaletteSection] {
        var seen = Set<String>()
        var order: [String] = []
        var grouped: [String: [PaletteItem]] = [:]
        for item in items {
            let cat = item.category ?? ""
            if seen.insert(cat).inserted { order.append(cat) }
            grouped[cat, default: []].append(item)
        }
        return order.map { cat in
            PaletteSection(header: cat.isEmpty ? nil : cat, items: grouped[cat] ?? [])
        }
    }
}

// MARK: - Fuzzy

/// Returns a score (lower = better match) or nil if no match.
/// 0 = exact prefix, <10 = substring hit, <50 = subsequence hit.
func fuzzyScore(query: String, target: String) -> Int? {
    let q = query.lowercased()
    let t = target.lowercased()
    guard !q.isEmpty else { return 0 }
    if t.hasPrefix(q) { return 0 }
    if let range = t.range(of: q) {
        return 5 + t.distance(from: t.startIndex, to: range.lowerBound)
    }
    // Subsequence
    var qi = q.startIndex
    for ch in t where ch == q[qi] {
        qi = q.index(after: qi)
        if qi == q.endIndex { return 40 + (t.count - q.count) }
    }
    return nil
}

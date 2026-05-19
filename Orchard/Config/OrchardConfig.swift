import Foundation

/// Generates the two ghostty config files Orchard wraps around the user's
/// own Ghostty config. The user is the source of truth for every Ghostty
/// setting; Orchard provides first-launch defaults that the user overrides,
/// and a minimal must-win overrides file for keys Orchard can't let the
/// renderer control (currently: background-opacity, background-blur — both
/// required for the window-level translucency in `WindowAppearance`).
///
/// `GhosttyApp.loadConfig` loads them in this order:
///   defaults → user's Ghostty config → overrides
/// libghostty does last-wins merge, so the user wins over our defaults and
/// our overrides win over the user.
///
/// See the README for the full list of Ghostty config settings Orchard honors
/// and the small set it ignores or overrides.
@MainActor @Observable
final class OrchardConfig {
    static let shared = OrchardConfig()

    let defaultsURL: URL
    let overridesURL: URL

    private init() {
        let dir = FileStorage.appSupportDirectory()
        defaultsURL = dir.appendingPathComponent("orchard-defaults.conf")
        overridesURL = dir.appendingPathComponent("orchard-overrides.conf")
        regenerate()
    }

    var defaultsPath: String { defaultsURL.path }
    var overridesPath: String { overridesURL.path }

    /// Rewrite both wrapper config files. Cheap and idempotent; safe to call
    /// on launch and whenever Orchard-side state changes that's reflected in
    /// either file.
    func regenerate(isDark: Bool? = nil) {
        let defaults = [
            // First-launch tasteful UX. User's Ghostty config overrides any of
            // these without needing to know they exist. Anything we'd set to
            // ghostty's own default (e.g. scrollbar=system) isn't listed —
            // libghostty already does the right thing.
            "theme = \"Rose Pine\"",
            "font-size = 12",
            "macos-option-as-alt = true",
            "window-padding-x = 16",
            "window-padding-y = 16",
        ].joined(separator: "\n") + "\n"
        try? Data(defaults.utf8).write(to: defaultsURL, options: .atomic)

        var overrides = [
            // Orchard composites window translucency at the AppKit level —
            // ghostty must draw a fully transparent terminal or we'd double-
            // tint. See WindowAppearance.swift.
            "background-opacity = 0",
            // We call CGSSetWindowBackgroundBlurRadius ourselves; ghostty's
            // own blur would compose on top of it.
            "background-blur = 0",
        ]

        // libghostty doesn't reliably re-evaluate `theme = "dark:X,light:Y"`
        // conditional themes when the app's color scheme changes, so resolve
        // the conditional here and write it as a flat override. The override
        // file loads last (defaults → user → overrides), so this wins over
        // the user's conditional spec without us having to edit their config.
        if let isDark, let resolvedTheme = resolveConditionalTheme(isDark: isDark) {
            // Always quote — theme names can contain spaces ("3024 Day").
            let escaped = resolvedTheme.replacingOccurrences(of: "\"", with: "\\\"")
            overrides.append("theme = \"\(escaped)\"")
        }

        let overridesText = overrides.joined(separator: "\n") + "\n"
        try? Data(overridesText.utf8).write(to: overridesURL, options: .atomic)
    }

    private func resolveConditionalTheme(isDark: Bool) -> String? {
        let path = Preferences.shared.expandedUserGhosttyConfigPath
        guard !path.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        // Walk every line of the user's config; the LAST `theme =` wins (the
        // user might have multiple in includes/overrides). Look for entries of
        // the form `theme = "dark:Adventure,light:3024 Day"` (with or without
        // quotes; comma-separated sides; each side prefixed by `dark:` or
        // `light:`). If no conditional is present, return nil — there's
        // nothing to resolve, the user's plain theme will be loaded normally.
        var resolved: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("theme") else { continue }
            let after = line.dropFirst("theme".count).drop(while: { $0 == " " || $0 == "\t" })
            guard after.first == "=" else { continue }
            var value = after.dropFirst().trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if let side = pickConditionalSide(value, isDark: isDark) {
                resolved = side
            }
        }
        return resolved
    }

    private func pickConditionalSide(_ value: String, isDark: Bool) -> String? {
        var darkSide: String?
        var lightSide: String?
        var hasConditional = false
        for piece in value.split(separator: ",") {
            let part = piece.trimmingCharacters(in: .whitespaces)
            if part.lowercased().hasPrefix("dark:") {
                darkSide = String(part.dropFirst("dark:".count)).trimmingCharacters(in: .whitespaces)
                hasConditional = true
            } else if part.lowercased().hasPrefix("light:") {
                lightSide = String(part.dropFirst("light:".count)).trimmingCharacters(in: .whitespaces)
                hasConditional = true
            }
        }
        guard hasConditional else { return nil }
        return isDark ? darkSide : lightSide
    }
}

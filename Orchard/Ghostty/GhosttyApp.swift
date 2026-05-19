import AppKit
import Foundation
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.thdxg.orchard", category: "GhosttyApp")

/// Manages the libghostty application lifecycle: init, config, tick loop, color queries.
@MainActor @Observable
final class GhosttyApp {
    static let shared = GhosttyApp()

    @ObservationIgnored
    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private(set) var configVersion = 0
    @ObservationIgnored
    private var tickTimer: Timer?
    @ObservationIgnored
    private let callbacks = GhosttyCallbacks()
    @ObservationIgnored
    private var appearanceObserver: NSObjectProtocol?
    @ObservationIgnored
    private var lastSyncedSchemeRaw: ghostty_color_scheme_e.RawValue?
    /// The most recent background color a surface reported via libghostty's
    /// COLOR_CHANGE action. Preferred over `configColor("background")` because
    /// it reflects the *resolved* color after conditional themes
    /// (`theme = "dark:X,light:Y"`) have been evaluated for the current
    /// system color scheme. nil until the first surface fires the event.
    private(set) var resolvedBackgroundColor: NSColor?
    private(set) var resolvedForegroundColor: NSColor?

    private init() {
        resolveResources()
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            logger.error("ghostty_init failed")
            return
        }
        let (cfgOpt, _) = loadConfig()
        guard let cfg = cfgOpt else {
            logger.error("ghostty_config_new failed")
            return
        }

        var rt = ghostty_runtime_config_s()
        rt.userdata = Unmanaged.passUnretained(self).toOpaque()
        rt.supports_selection_clipboard = true
        rt.wakeup_cb = { _ in GhosttyApp.shared.callbacks.wakeup() }
        rt.action_cb = { _, target, action in GhosttyApp.shared.callbacks.action(target: target, action: action) }
        rt.read_clipboard_cb = { ud, loc, state in GhosttyApp.shared.callbacks.readClipboard(ud: ud, location: loc, state: state) }
        rt.confirm_read_clipboard_cb = { ud, content, state, _ in
            GhosttyApp.shared.callbacks.confirmReadClipboard(ud: ud, content: content, state: state)
        }
        rt.write_clipboard_cb = { _, _, content, len, _ in GhosttyApp.shared.callbacks.writeClipboard(content: content, len: UInt(len)) }
        rt.close_surface_cb = { ud, _ in GhosttyApp.shared.callbacks.closeSurface(ud: ud) }

        guard let createdApp = ghostty_app_new(&rt, cfg) else {
            logger.error("ghostty_app_new failed")
            ghostty_config_free(cfg)
            return
        }
        app = createdApp
        config = cfg

        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    /// Push the current system color scheme into libghostty and start observing
    /// system appearance changes. Must be called AFTER `GhosttyApp.shared` has
    /// finished initializing — `ghostty_app_set_color_scheme` can fire runtime
    /// callbacks that recurse into `GhosttyApp.shared`, which traps during
    /// static-let init.
    func installAppearanceTracking() {
        syncColorScheme()
        guard appearanceObserver == nil else { return }
        appearanceObserver = DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncColorScheme() }
        }
    }

    // MARK: - Color scheme

    private static func currentColorScheme() -> ghostty_color_scheme_e {
        // NSApp can be nil very early in launch. Fall back to the system
        // AppleInterfaceStyle preference in that case so we still pick the
        // right initial theme.
        let appearance = NSApp?.effectiveAppearance
        if let appearance {
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]) ?? .aqua
            switch match {
            case .darkAqua, .vibrantDark:
                return GHOSTTY_COLOR_SCHEME_DARK
            default:
                return GHOSTTY_COLOR_SCHEME_LIGHT
            }
        }
        let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        return style == "Dark" ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    }

    /// Push the current system color scheme into libghostty. Each affected
    /// surface re-resolves its conditional theme and reports the new
    /// foreground/background via the COLOR_CHANGE action callback — see
    /// `reportResolvedColor(kind:nsColor:)` and the COLOR_CHANGE handler in
    /// `GhosttyCallbacks.action`. We also resolve the user's
    /// `theme = "dark:X,light:Y"` conditional ourselves and rewrite the
    /// override config so `configColor("background")` returns the right
    /// resolved value (libghostty doesn't update its config object's stored
    /// colors when the app scheme flips).
    func syncColorScheme() {
        let scheme = Self.currentColorScheme()
        let schemeChanged = lastSyncedSchemeRaw != scheme.rawValue
        lastSyncedSchemeRaw = scheme.rawValue

        if let app { ghostty_app_set_color_scheme(app, scheme) }
        for view in GhosttyTerminalNSView.allLiveViews() {
            if let surface = view.surface {
                ghostty_surface_set_color_scheme(surface, scheme)
            }
        }

        if schemeChanged {
            let isDark = scheme.rawValue == GHOSTTY_COLOR_SCHEME_DARK.rawValue
            // Drop the previously cached resolved color so the next read
            // falls back to configColor while the new config loads.
            resolvedBackgroundColor = nil
            resolvedForegroundColor = nil
            OrchardConfig.shared.regenerate(isDark: isDark)
            reloadConfig()
        }
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    // MARK: - Config

    /// Result of a config (re)load. `missingUserConfigPath` is populated when
    /// the user pointed to a path that doesn't exist on disk — useful to
    /// surface from the Settings reload button. `diagnostics` are libghostty's
    /// parse warnings/errors (unknown keys, bad values, etc.). Both are
    /// empty/nil on a clean reload.
    struct ReloadResult {
        var missingUserConfigPath: String?
        var diagnostics: [String]
    }

    @discardableResult
    func reloadConfig() -> ReloadResult {
        guard let app else { return ReloadResult(diagnostics: []) }
        let (newConfig, result) = loadConfig()
        guard let newConfig else { return result }
        ghostty_app_update_config(app, newConfig)
        // Also update each existing surface so changes take effect immediately
        for view in GhosttyTerminalNSView.allLiveViews() {
            if let surface = view.surface {
                ghostty_surface_update_config(surface, newConfig)
            }
        }
        if let old = config { ghostty_config_free(old) }
        config = newConfig
        configVersion += 1
        NotificationCenter.default.post(name: .orchardConfigDidChange, object: nil)
        return result
    }

    /// Reload and surface any user-visible errors (missing file, parse errors)
    /// as a modal alert. Silent on success. Used by both the Settings reload
    /// button and the rebindable "Reload Ghostty config" hotkey.
    func reloadAndReport() {
        let result = reloadConfig()
        var lines: [String] = []
        if let missing = result.missingUserConfigPath {
            lines.append("File not found: \(missing)")
        }
        if !result.diagnostics.isEmpty {
            lines.append(contentsOf: result.diagnostics)
        }
        guard !lines.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText =
            result.missingUserConfigPath != nil
                ? "Ghostty config not found"
                : "Issues in your Ghostty config"
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.alertStyle = result.missingUserConfigPath != nil ? .warning : .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    var backgroundColor: NSColor {
        resolvedBackgroundColor
            ?? configColor("background")
            ?? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.14, alpha: 1)
    }
    var foregroundColor: NSColor {
        resolvedForegroundColor ?? configColor("foreground") ?? .white
    }
    var accentColor: NSColor { paletteColor(at: 4) ?? foregroundColor }

    /// Called from the libghostty action callback when a surface reports a new
    /// resolved bg/fg color. Caches it and notifies listeners so window
    /// appearance can re-paint.
    func reportResolvedColor(kind: ghostty_action_color_kind_e, nsColor: NSColor) {
        switch kind {
        case GHOSTTY_ACTION_COLOR_KIND_BACKGROUND:
            guard resolvedBackgroundColor != nsColor else { return }
            resolvedBackgroundColor = nsColor
        case GHOSTTY_ACTION_COLOR_KIND_FOREGROUND:
            guard resolvedForegroundColor != nsColor else { return }
            resolvedForegroundColor = nsColor
        default:
            return
        }
        NotificationCenter.default.post(name: .orchardConfigDidChange, object: nil)
    }

    func paletteColor(at index: Int) -> NSColor? {
        guard let config, (0 ..< 256).contains(index) else { return nil }
        var palette = ghostty_config_palette_s()
        let key = "palette"
        guard ghostty_config_get(config, &palette, key, UInt(key.utf8.count)) else { return nil }
        let c = withUnsafePointer(to: &palette.colors) {
            $0.withMemoryRebound(to: ghostty_config_color_s.self, capacity: 256) { $0[index] }
        }
        return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    private func configColor(_ key: String) -> NSColor? {
        guard let config else { return nil }
        var color = ghostty_config_color_s()
        guard ghostty_config_get(config, &color, key, UInt(key.utf8.count)) else { return nil }
        return NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
    }

    private func loadConfig() -> (ghostty_config_t?, ReloadResult) {
        var result = ReloadResult(diagnostics: [])
        guard let cfg = ghostty_config_new() else { return (nil, result) }

        // Three-layer ghostty config:
        //   1. Orchard defaults — tasteful first-launch values.
        //   2. User's Ghostty config — overrides any default. Source of truth
        //      for all ghostty-shaped settings (theme, font, palette, keybinds,
        //      shell integration, etc.).
        //   3. Orchard overrides — keys Orchard absolutely needs to control,
        //      currently just background-opacity/blur for the window-level
        //      translucency contract. Loaded last so it overrides the user.
        // libghostty merges last-wins, so this ordering produces:
        //   Orchard defaults < user's Ghostty config < Orchard overrides
        OrchardConfig.shared.defaultsPath.withCString { ghostty_config_load_file(cfg, $0) }
        let userPath = Preferences.shared.expandedUserGhosttyConfigPath
        if !userPath.isEmpty {
            if FileManager.default.fileExists(atPath: userPath) {
                userPath.withCString { ghostty_config_load_file(cfg, $0) }
            } else {
                logger.info("user Ghostty config not found at \(userPath, privacy: .public); skipping")
                result.missingUserConfigPath = userPath
            }
        }
        OrchardConfig.shared.overridesPath.withCString { ghostty_config_load_file(cfg, $0) }
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)

        // Collect ghostty's diagnostics (parse errors, unknown keys, bad
        // values). Log them and surface to the caller so the Settings reload
        // button can show them in an alert.
        let diagCount = ghostty_config_diagnostics_count(cfg)
        for i in 0 ..< diagCount {
            let diag = ghostty_config_get_diagnostic(cfg, i)
            if let msg = diag.message {
                let s = String(cString: msg)
                logger.warning("config: \(s, privacy: .public)")
                result.diagnostics.append(s)
            }
        }

        return (cfg, result)
    }

    private static let resourcePaths = [
        "/Applications/Ghostty.app/Contents/Resources/ghostty",
        NSHomeDirectory() + "/Applications/Ghostty.app/Contents/Resources/ghostty",
    ]

    private func resolveResources() {
        if let existing = getenv("GHOSTTY_RESOURCES_DIR").map({ String(cString: $0) }) {
            guard Self.resourcePaths.contains(where: { existing.hasPrefix($0) }) else {
                unsetenv("GHOSTTY_RESOURCES_DIR")
                return
            }
            return
        }
        for path in Self.resourcePaths where FileManager.default.fileExists(atPath: path + "/shell-integration") {
            setenv("GHOSTTY_RESOURCES_DIR", path, 1)
            return
        }
    }
}

import Foundation
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.thdxg.orchard", category: "GhosttyConfigLoader")

/// Builds a libghostty config object from Orchard's three-layer config stack
/// and collects parse diagnostics. Pure — it reads `OrchardConfig`/`Preferences`
/// and touches no `GhosttyApp` instance state, so both app init and reloads
/// share one code path.
enum GhosttyConfigLoader {
    static func load() -> (ghostty_config_t?, GhosttyApp.ReloadResult) {
        var result = GhosttyApp.ReloadResult(diagnostics: [])
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
}

import Foundation

/// Launches the VSCode `code` CLI to open a file from the diff. Uses `-r` so
/// the file lands in the most recently used VSCode window when one is already
/// open, matching the user's expectation that toggling between Orchard and
/// VSCode reuses the same project window.
enum EditorLauncher {
    /// Common install locations for the `code` CLI. We don't trust PATH —
    /// Process inherits a minimal environment and the user's shell PATH isn't
    /// propagated, so well-known absolute paths are more reliable.
    private static let codeCandidates = [
        "/opt/homebrew/bin/code",
        "/usr/local/bin/code",
        "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
        "/Applications/VSCode.app/Contents/Resources/app/bin/code",
    ]

    static func openInVSCode(relativePath: String, projectRoot: String) {
        let fullPath = (projectRoot as NSString).appendingPathComponent(relativePath)
        guard let exec = codeCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            NSLog("Orchard: VS Code `code` CLI not found in known locations")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exec)
        // `-r` reuses the most recently used window. If no VSCode window is
        // open, it opens a new one — also the desired behavior.
        process.arguments = ["-r", fullPath]
        do {
            try process.run()
        } catch {
            NSLog("Orchard: failed to launch VS Code: \(error.localizedDescription)")
        }
    }
}

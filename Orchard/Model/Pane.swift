import Foundation

/// A pane is the leaf of the split tree — one terminal surface.
@MainActor @Observable
final class Pane: Identifiable {
    let id = UUID()
    let projectPath: String
    var title: String = "Terminal"
    var assistantProcessName: String?
    var isAssistantQueryRunning = false
    let searchState = TerminalSearchState()

    /// The live terminal NSView for this pane. Created lazily the first time
    /// it's requested, destroyed explicitly when the pane is removed from the
    /// tree. Owning the view on the model (instead of in a separate cache or
    /// inside SwiftUI) keeps the underlying ghostty surface alive across any
    /// SwiftUI view churn: tab switches, split tree reshapes, window hide/show.
    /// Not observed — SwiftUI should never re-render just because this changes.
    @ObservationIgnored
    private var _nsView: GhosttyTerminalNSView?

    func ensureNSView() -> GhosttyTerminalNSView {
        if let existing = _nsView { return existing }
        let view = GhosttyTerminalNSView(workingDirectory: projectPath)
        _nsView = view
        return view
    }

    var nsView: GhosttyTerminalNSView? { _nsView }

    /// Tear down the ghostty surface and null out callbacks. Call when the
    /// pane is removed from the tree. Safe to call multiple times.
    func destroySurface() {
        guard let view = _nsView else { return }
        // Null callbacks before destroy so any in-flight ghostty events
        // triggered by destroySurface() itself can't re-enter.
        view.onProcessExit = nil
        view.onTitleChange = nil
        view.onSearchStart = nil
        view.onSearchEnd = nil
        view.onSearchTotal = nil
        view.onSearchSelected = nil
        view.onCommandSubmitted = nil
        view.onCommandFinished = nil
        view.onProgressActivityChange = nil
        view.onFocus = nil
        view.onSplitRequest = nil
        view.destroySurface()
        _nsView = nil
        // Keep the NSView alive for a runloop tick so any in-flight ghostty
        // callback (which holds an unretained pointer to the view) can drain
        // before the view is deallocated. Without this, SwiftUI can remove
        // the view from its superview the same turn we destroy the surface,
        // deallocating the NSView before ghostty has finished unwinding.
        DispatchQueue.main.async { _ = view }
    }

    var processTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Self.defaultShellName }
        let tokens = trimmed.split(whereSeparator: \ .isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return Self.defaultShellName }
        if let candidate = tokens.first(where: { !Self.isPathLike($0) && !Self.isNoise($0) }) {
            return candidate
        }
        return Self.defaultShellName
    }

    private static let defaultShellName: String = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return (shell as NSString).lastPathComponent
    }()

    var sidebarSegmentTitle: String {
        if let assistantProcessName { return assistantProcessName }
        return processTitle
    }

    func didSubmitCommand(_ command: String) {
        guard let assistant = Self.assistantProcessName(from: command) else { return }
        assistantProcessName = assistant
    }

    private static func isPathLike(_ token: String) -> Bool {
        token.contains("/") || token.hasPrefix("~")
    }

    private static func isNoise(_ token: String) -> Bool {
        token.allSatisfy { !$0.isLetter && !$0.isNumber }
    }

    private static func assistantProcessName(from command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        while let first = tokens.first {
            let executable = (first as NSString).lastPathComponent.lowercased()
            if first.contains("="), !first.hasPrefix("=") {
                tokens.removeFirst()
                continue
            }
            if executable == "env" || executable == "sudo" || executable == "command" {
                tokens.removeFirst()
                continue
            }
            if ["npx", "bunx", "pnpm", "yarn"].contains(executable), tokens.count > 1 {
                tokens.removeFirst()
                if tokens.first == "dlx" || tokens.first == "exec" {
                    tokens.removeFirst()
                }
                while tokens.first?.hasPrefix("-") == true {
                    tokens.removeFirst()
                }
                continue
            }
            break
        }
        guard let first = tokens.first else { return nil }
        let executable = (first as NSString).lastPathComponent.lowercased()
        if executable == "claude" || executable.hasPrefix("claude-") { return "claude" }
        if executable == "codex" || executable.hasPrefix("codex-") || executable.hasSuffix("/codex") { return "codex" }
        return nil
    }

    init(projectPath: String) {
        self.projectPath = projectPath
    }
}

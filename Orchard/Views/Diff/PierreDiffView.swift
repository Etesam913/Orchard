import AppKit
import SwiftUI
import WebKit

struct PierreDiffView: NSViewRepresentable {
    let diff: String
    /// Absolute path to the active project — diff entries are repo-relative,
    /// so we need this to resolve them when "open in editor" fires.
    let projectPath: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "orchardCopy")
        configuration.userContentController.add(context.coordinator, name: "orchardOpenInEditor")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")

        // Load with an https baseURL rather than file:// so dynamic
        // `import()` from esm.sh is allowed. WKWebView blocks cross-origin
        // module imports from file:// origins regardless of CSP, surfacing as
        // "Importing a module script failed.".
        let baseURL = URL(string: "https://orchard.local/")
        if let htmlURL = Bundle.main.url(forResource: "DiffViewer", withExtension: "html"),
           let html = try? String(contentsOf: htmlURL, encoding: .utf8) {
            webView.loadHTMLString(html, baseURL: baseURL)
        } else {
            webView.loadHTMLString(DiffViewerHTML.source, baseURL: baseURL)
        }

        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.projectPath = projectPath
        context.coordinator.render(diff: diff, in: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var projectPath: String = ""
        private var isPageLoaded = false
        private var pendingDiff: String?
        private var renderedDiff: String?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "orchardCopy":
                guard let text = message.body as? String, !text.isEmpty else { return }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            case "orchardOpenInEditor":
                guard let body = message.body as? [String: Any],
                      let relativePath = body["path"] as? String,
                      !relativePath.isEmpty,
                      !projectPath.isEmpty
                else { return }
                EditorLauncher.openInVSCode(relativePath: relativePath, projectRoot: projectPath)
            default: break
            }
        }

        func render(diff: String, in webView: WKWebView) {
            guard diff != renderedDiff else { return }
            pendingDiff = diff
            self.webView = webView
            flushPendingDiff()
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            self.webView = webView
            isPageLoaded = true
            flushPendingDiff()
        }

        func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            showBridgeError(error.localizedDescription, in: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
            showBridgeError(error.localizedDescription, in: webView)
        }

        private func flushPendingDiff() {
            guard isPageLoaded, let webView, let diff = pendingDiff else { return }

            let payload = ["diff": diff]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8)
            else {
                showBridgeError("Unable to serialize diff payload.", in: webView)
                return
            }

            webView.evaluateJavaScript("window.orchardRenderDiff(\(json));") { [weak self] _, error in
                if let error {
                    self?.showBridgeError(error.localizedDescription, in: webView)
                    return
                }

                self?.renderedDiff = diff
                self?.pendingDiff = nil
            }
        }

        private func showBridgeError(_ message: String, in webView: WKWebView) {
            let payload = ["message": message]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8)
            else { return }

            webView.evaluateJavaScript("window.orchardShowError?.(\(json));")
        }
    }
}

/// Launches the VSCode `code` CLI to open a file from the diff. Uses `-r` so
/// the file lands in the most recently used VSCode window when one is already
/// open, matching the user's expectation that toggling between Orchard and
/// VSCode reuses the same project window.
private enum EditorLauncher {
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

private enum DiffViewerHTML {
    static let source = """
    <!doctype html>
    <html lang="en">
    <head><meta charset="utf-8"><title>Diff Viewer</title></head>
    <body><main id="root"></main></body>
    </html>
    """
}

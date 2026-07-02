import AppKit
import SwiftUI
import WebKit

/// WebKit-backed diff renderer. SwiftUI hosts the sidebar state, while WebKit
/// handles the large text/layout surface where it is substantially cheaper.
struct PierreDiffView: NSViewRepresentable {
    let diff: String
    let projectPath: String
    /// Render side-by-side (old | new) instead of the unified single column.
    var splitView: Bool = false
    /// Current text typed into the diff search field.
    var searchQuery: String = ""
    /// Bumped (debounced) as the user types, so the highlight pass and match
    /// count refresh while typing.
    var searchToken: Int = 0
    /// Bumped on each Enter to jump to the next match without re-scanning.
    var searchNextToken: Int = 0
    /// Reports `(matchCount, currentIndex)` back as the WebView searches.
    /// `currentIndex` is 1-based, or 0 when there are no matches.
    var onSearchResult: ((Int, Int) -> Void)? = nil

    /// highlight.js (Common build, BSD-3) read once from the app bundle and
    /// injected inline into the diff HTML — the WebView loads from a synthetic
    /// base URL, so a `<script src=…>` would not resolve.
    private static let highlightJS: String = {
        guard let url = Bundle.main.url(forResource: "highlight.min", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return js
    }()

    private static let diffHTML = DiffViewerHTML.source
        .replacingOccurrences(of: "/*__ORCHARD_HLJS__*/", with: highlightJS)

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "orchardCopy")
        configuration.userContentController.add(context.coordinator, name: "orchardOpenInEditor")
        configuration.userContentController.add(context.coordinator, name: "orchardSearchResult")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(Self.diffHTML, baseURL: URL(string: "https://orchard.local/"))

        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.projectPath = projectPath
        context.coordinator.onSearchResult = onSearchResult
        context.coordinator.currentSearchQuery = searchQuery
        context.coordinator.render(diff: diff, split: splitView, in: webView)
        context.coordinator.runSearch(query: searchQuery, token: searchToken, in: webView)
        context.coordinator.advanceSearch(token: searchNextToken, in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "orchardCopy")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "orchardOpenInEditor")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "orchardSearchResult")
        webView.navigationDelegate = nil
        coordinator.webView = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var projectPath: String = ""
        var onSearchResult: ((Int, Int) -> Void)?
        /// The query currently in the field. Kept so the highlight pass can be
        /// re-applied after a diff re-render (e.g. switching back to a project
        /// whose search was active) — rendering wipes the prior `<mark>`s.
        var currentSearchQuery = ""

        private var isPageLoaded = false
        private var pendingDiff: String?
        private var pendingSplit = false
        private var renderedDiff: String?
        private var renderedSplit: Bool?
        private var lastSearchToken = 0
        private var lastSearchNextToken = 0

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
            case "orchardSearchResult":
                guard let body = message.body as? [String: Any],
                      let count = body["count"] as? Int,
                      let index = body["index"] as? Int
                else { return }
                onSearchResult?(count, index)
            default:
                break
            }
        }

        func render(diff: String, split: Bool, in webView: WKWebView) {
            guard diff != renderedDiff || split != renderedSplit else { return }
            pendingDiff = diff
            pendingSplit = split
            self.webView = webView
            flushPendingDiff()
        }

        /// Re-run the highlight pass for the current query. Only fires when the
        /// token changes so a fresh `updateNSView` (e.g. a diff refresh) doesn't
        /// re-trigger the previous search.
        func runSearch(query: String, token: Int, in webView: WKWebView) {
            guard token != lastSearchToken else { return }
            lastSearchToken = token

            let payload = ["query": query]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8)
            else { return }

            webView.evaluateJavaScript("window.orchardSearch?.(\(json));")
        }

        /// Jump to the next match (Enter), without re-scanning.
        func advanceSearch(token: Int, in webView: WKWebView) {
            guard token != lastSearchNextToken else { return }
            lastSearchNextToken = token
            webView.evaluateJavaScript("window.orchardSearchNext?.();")
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

            let split = pendingSplit
            let payload: [String: Any] = ["diff": diff, "split": split, "projectPath": projectPath]
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
                self?.renderedSplit = split
                self?.pendingDiff = nil
                self?.reapplySearch(in: webView)
            }
        }

        /// Re-highlight the active query after the diff DOM was rebuilt.
        private func reapplySearch(in webView: WKWebView) {
            guard !currentSearchQuery.isEmpty else { return }
            let payload = ["query": currentSearchQuery]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8)
            else { return }
            webView.evaluateJavaScript("window.orchardSearch?.(\(json));")
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

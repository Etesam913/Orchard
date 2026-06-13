import AppKit
import SwiftUI
import WebKit

/// WebKit-backed diff renderer. SwiftUI hosts the sidebar state, while WebKit
/// handles the large text/layout surface where it is substantially cheaper.
struct PierreDiffView: NSViewRepresentable {
    let diff: String
    let projectPath: String
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
        webView.loadHTMLString(DiffViewerHTML.source, baseURL: URL(string: "https://orchard.local/"))

        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.projectPath = projectPath
        context.coordinator.onSearchResult = onSearchResult
        context.coordinator.currentSearchQuery = searchQuery
        context.coordinator.render(diff: diff, in: webView)
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
        private var renderedDiff: String?
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

        func render(diff: String, in webView: WKWebView) {
            guard diff != renderedDiff else { return }
            pendingDiff = diff
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

private enum DiffViewerHTML {
    static let source = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Orchard Diff Viewer</title>
<style>
:root {
    color-scheme: light dark;
    background: transparent;
    color: CanvasText;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
    --mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, Monaco, monospace;
    --border: color-mix(in srgb, CanvasText 14%, transparent);
    --soft-border: color-mix(in srgb, CanvasText 9%, transparent);
    --header-bg: color-mix(in srgb, CanvasText 6%, Canvas);
    --gutter-fg: color-mix(in srgb, CanvasText 45%, transparent);
    --hunk-fg: color-mix(in srgb, CanvasText 55%, transparent);
    --hunk-bg: color-mix(in srgb, CanvasText 4%, transparent);
    --add-fg: light-dark(#1a7f37, #82e08a);
    --add-bg: light-dark(#dafbe1, color-mix(in srgb, #2ea043 18%, transparent));
    --add-gutter: light-dark(#aceebb, color-mix(in srgb, #2ea043 35%, transparent));
    --del-fg: light-dark(#d1242f, #ff8a87);
    --del-bg: light-dark(#ffebe9, color-mix(in srgb, #f85149 18%, transparent));
    --del-gutter: light-dark(#ffc1bf, color-mix(in srgb, #f85149 35%, transparent));
}
html, body {
    width: 100%;
    height: 100%;
    margin: 0;
    background: transparent;
}
body {
    overflow-x: hidden;
    overflow-y: auto;
    font-size: 12px;
    line-height: 1.5;
    -webkit-font-smoothing: antialiased;
}
#root {
    box-sizing: border-box;
    width: 100%;
    min-height: 100%;
    padding: 14px;
}
.message {
    box-sizing: border-box;
    margin: 0;
    padding: 10px 12px;
    border: 1px solid var(--border);
    border-radius: 6px;
    color: color-mix(in srgb, CanvasText 72%, transparent);
    background: color-mix(in srgb, Canvas 72%, transparent);
    white-space: pre-wrap;
}
.patch-file {
    margin: 0 0 12px;
    border: 1px solid var(--soft-border);
    border-radius: 8px;
    overflow: clip;
    background: color-mix(in srgb, CanvasText 2%, Canvas);
    box-shadow: 0 1px 2px color-mix(in srgb, CanvasText 8%, transparent);
}
.patch-file-header {
    display: flex;
    align-items: stretch;
    min-width: 0;
    position: sticky;
    top: 0;
    z-index: 1;
    border-bottom: 1px solid var(--soft-border);
    background: color-mix(in srgb, Canvas 60%, var(--header-bg));
    backdrop-filter: saturate(180%) blur(20px);
    -webkit-backdrop-filter: saturate(180%) blur(20px);
    color: color-mix(in srgb, CanvasText 88%, transparent);
    font-size: 12px;
    font-weight: 590;
    letter-spacing: -0.01em;
}
.patch-file.collapsed .patch-file-header {
    border-bottom: none;
}
.patch-file-toggle {
    display: inline-flex;
    align-items: center;
    justify-content: flex-start;
    flex: 1 1 auto;
    min-width: 0;
    gap: 8px;
    padding: 6px 10px;
    border: 0;
    background: transparent;
    color: inherit;
    font: inherit;
    text-align: left;
}
.patch-file-toggle:hover, .open-in-editor:hover {
    background: color-mix(in srgb, CanvasText 8%, transparent);
}
.chevron {
    flex: 0 0 auto;
    width: 10px;
    height: 10px;
    transition: transform 0.15s ease;
    color: color-mix(in srgb, CanvasText 60%, transparent);
}
.patch-file.collapsed .chevron {
    transform: rotate(-90deg);
}
.path {
    flex: 1 1 auto;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-family: var(--mono);
    font-size: 11px;
    font-weight: 500;
}
.patch-file-trailing {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 10px;
    flex: 0 0 auto;
}
.badge {
    flex: 0 0 auto;
    font-size: 9.5px;
    font-weight: 600;
    padding: 2px 7px;
    border-radius: 999px;
    background: color-mix(in srgb, CanvasText 8%, transparent);
    color: color-mix(in srgb, CanvasText 75%, transparent);
    text-transform: uppercase;
    letter-spacing: 0.05em;
}
.badge.added { background: var(--add-bg); color: var(--add-fg); }
.badge.deleted { background: var(--del-bg); color: var(--del-fg); }
.badge.renamed { background: color-mix(in srgb, #ffd34d 25%, transparent); color: light-dark(#7a5d00, #ffd34d); }
.open-in-editor {
    flex: 0 0 auto;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 22px;
    height: 22px;
    padding: 0;
    border: 0;
    border-radius: 4px;
    background: transparent;
    color: color-mix(in srgb, CanvasText 55%, transparent);
}
.open-in-editor svg {
    width: 14px;
    height: 14px;
    display: block;
}
.patch-file-body {
    overflow-x: auto;
    overflow-y: hidden;
}
.patch-file.collapsed .patch-file-body {
    display: none;
}
.diff-stat {
    font-family: var(--mono);
    font-size: 10.5px;
    font-weight: 600;
    letter-spacing: 0.02em;
    font-variant-numeric: tabular-nums;
}
.diff-stat .add { color: var(--add-fg); }
.diff-stat .del { color: var(--del-fg); }
.diff-table {
    border-collapse: collapse;
    width: max-content;
    min-width: 100%;
    font-family: var(--mono);
    font-size: 11.5px;
    font-variant-numeric: tabular-nums;
}
.diff-table td {
    padding: 0;
    vertical-align: top;
}
.hunk-header-row > td {
    padding: 2px 10px;
    color: var(--hunk-fg);
    background: var(--hunk-bg);
    border-top: 1px solid var(--soft-border);
    border-bottom: 1px solid var(--soft-border);
    font-size: 11px;
    white-space: pre;
}
.hunk-header-row:first-child > td {
    border-top: none;
}
.diff-row > .gutter {
    width: 1%;
    padding: 0 6px;
    border-right: 1px solid var(--soft-border);
    background: color-mix(in srgb, CanvasText 2%, transparent);
    color: var(--gutter-fg);
    font-size: 11px;
    text-align: right;
    white-space: nowrap;
    user-select: none;
}
.diff-row > .content {
    width: 100%;
    min-width: 0;
    padding: 0 10px;
    white-space: pre;
}
.diff-row.add > td { background: var(--add-bg); color: var(--add-fg); }
.diff-row.add > .gutter { background: var(--add-gutter); color: var(--add-fg); }
.diff-row.del > td { background: var(--del-bg); color: var(--del-fg); }
.diff-row.del > .gutter { background: var(--del-gutter); color: var(--del-fg); }
.diff-row.context > .content { color: CanvasText; }
.diff-row.nonewline > .content {
    color: var(--hunk-fg);
    font-style: italic;
}
.diff-row > .content::before {
    user-select: none;
    -webkit-user-select: none;
}
.diff-row.add > .content::before { content: "+ "; }
.diff-row.del > .content::before { content: "- "; }
.diff-row.context > .content::before { content: "  "; }
.patch-file-notice {
    padding: 10px 12px;
    color: color-mix(in srgb, CanvasText 65%, transparent);
    font-style: italic;
}
mark.orchard-search-hit {
    background: light-dark(#fff3b0, #6d5a00);
    color: inherit;
    border-radius: 2px;
}
mark.orchard-search-hit.current {
    background: light-dark(#ffd43b, #b38600);
    box-shadow: 0 0 0 1px light-dark(#e6a700, #ffd43b);
}
</style>
</head>
<body>
<main id="root"><div class="message">Loading diff...</div></main>
<script>
(() => {
    const root = () => document.getElementById("root");

    function setMessage(text) {
        const r = root();
        r.innerHTML = "";
        const div = document.createElement("div");
        div.className = "message";
        div.textContent = text;
        r.appendChild(div);
    }

    function parseUnifiedDiff(input) {
        if (!input) return [];
        const lines = input.replace(/\r\n/g, "\n").split("\n");
        const files = [];
        let file = null;
        let hunk = null;
        let oldLine = 0;
        let newLine = 0;

        function startFile() {
            file = { oldPath: null, newPath: null, mode: "modified", binary: false, hunks: [] };
            files.push(file);
            hunk = null;
        }

        function cleanPath(raw) {
            const path = raw.trim().replace(/^"|"$/g, "");
            if (path === "/dev/null") return path;
            return path.replace(/^[ab]\//, "");
        }

        function startHunk(header) {
            const match = header.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/);
            if (!match) return false;
            if (!file) startFile();
            oldLine = Number(match[1]);
            newLine = Number(match[2]);
            hunk = { header, rows: [] };
            file.hunks.push(hunk);
            return true;
        }

        for (const line of lines) {
            if (line.startsWith("diff --git ")) {
                startFile();
                const match = line.match(/^diff --git a\/(.+?) b\/(.+)$/);
                if (match) {
                    file.oldPath = match[1];
                    file.newPath = match[2];
                }
                continue;
            }
            if (line.startsWith("--- ")) {
                if (!file) startFile();
                hunk = null;
                const path = cleanPath(line.slice(4));
                if (path === "/dev/null") file.mode = "added";
                else file.oldPath = file.oldPath || path;
                continue;
            }
            if (line.startsWith("+++ ")) {
                if (!file) startFile();
                hunk = null;
                const path = cleanPath(line.slice(4));
                if (path === "/dev/null") file.mode = "deleted";
                else file.newPath = file.newPath || path;
                continue;
            }
            if (line.startsWith("new file mode")) {
                if (file) file.mode = "added";
                continue;
            }
            if (line.startsWith("deleted file mode")) {
                if (file) file.mode = "deleted";
                continue;
            }
            if (line.startsWith("rename from ")) {
                if (file) {
                    file.mode = "renamed";
                    file.oldPath = line.slice("rename from ".length).trim();
                }
                continue;
            }
            if (line.startsWith("rename to ")) {
                if (file) {
                    file.mode = "renamed";
                    file.newPath = line.slice("rename to ".length).trim();
                }
                continue;
            }
            if (line.startsWith("Binary files ") || line.includes("GIT binary patch")) {
                if (!file) startFile();
                file.binary = true;
                continue;
            }
            if (line.startsWith("@@")) {
                startHunk(line);
                continue;
            }
            if (!hunk) continue;

            const marker = line[0];
            if (marker === "+") {
                hunk.rows.push({ kind: "add", oldNo: null, newNo: newLine, text: line.slice(1) });
                newLine++;
            } else if (marker === "-") {
                hunk.rows.push({ kind: "del", oldNo: oldLine, newNo: null, text: line.slice(1) });
                oldLine++;
            } else if (marker === "\\") {
                hunk.rows.push({ kind: "nonewline", oldNo: null, newNo: null, text: line });
            } else {
                hunk.rows.push({ kind: "context", oldNo: oldLine, newNo: newLine, text: marker === " " ? line.slice(1) : line });
                oldLine++;
                newLine++;
            }
        }

        for (const f of files) {
            if (f.binary) f.mode = "binary";
            else if (f.mode === "modified") {
                if (!f.oldPath && f.newPath) f.mode = "added";
                if (f.oldPath && !f.newPath) f.mode = "deleted";
            }
        }
        return files;
    }

    function shortenPath(path) {
        if (!path) return path;
        const parts = path.split("/").filter(Boolean);
        return parts.length > 3 ? ".../" + parts.slice(-3).join("/") : path;
    }

    function stats(file) {
        let adds = 0;
        let dels = 0;
        for (const hunk of file.hunks) {
            for (const row of hunk.rows) {
                if (row.kind === "add") adds++;
                if (row.kind === "del") dels++;
            }
        }
        return { adds, dels };
    }

    function svg(name) {
        const ns = "http://www.w3.org/2000/svg";
        const el = document.createElementNS(ns, "svg");
        el.setAttribute("viewBox", "0 0 100 100");
        el.setAttribute("fill", "none");
        el.setAttribute("aria-hidden", "true");
        const path = document.createElementNS(ns, "path");
        if (name === "chevron") {
            el.setAttribute("class", "chevron");
            el.setAttribute("viewBox", "0 0 10 10");
            path.setAttribute("d", "M2 3.5 L5 6.5 L8 3.5");
            path.setAttribute("stroke", "currentColor");
            path.setAttribute("stroke-width", "1.5");
            path.setAttribute("stroke-linecap", "round");
            path.setAttribute("stroke-linejoin", "round");
        } else {
            path.setAttribute("d", "M70 8 L92 18 V82 L70 92 L30 60 L14 72 L8 68 V32 L14 28 L30 40 Z M70 30 L40 50 L70 70 Z");
            path.setAttribute("fill", "currentColor");
            path.setAttribute("fill-rule", "evenodd");
        }
        el.appendChild(path);
        return el;
    }

    function renderFile(file, index) {
        const section = document.createElement("section");
        section.className = "patch-file";
        section.dataset.fileIndex = String(index);

        const header = document.createElement("header");
        header.className = "patch-file-header";

        const toggle = document.createElement("button");
        toggle.type = "button";
        toggle.className = "patch-file-toggle";
        toggle.setAttribute("aria-expanded", "true");
        toggle.appendChild(svg("chevron"));

        const path = document.createElement("span");
        path.className = "path";
        const fullPath = file.mode === "renamed" && file.oldPath && file.newPath && file.oldPath !== file.newPath
            ? `${file.oldPath} -> ${file.newPath}`
            : (file.newPath || file.oldPath || "(unknown)");
        const shortPath = file.mode === "renamed" && file.oldPath && file.newPath && file.oldPath !== file.newPath
            ? `${shortenPath(file.oldPath)} -> ${shortenPath(file.newPath)}`
            : shortenPath(fullPath);
        path.textContent = shortPath;
        path.title = fullPath;
        toggle.appendChild(path);
        header.appendChild(toggle);

        const trailing = document.createElement("span");
        trailing.className = "patch-file-trailing";
        const counts = stats(file);
        if (!file.binary && (counts.adds > 0 || counts.dels > 0)) {
            const stat = document.createElement("span");
            stat.className = "diff-stat";
            if (counts.adds > 0) {
                const add = document.createElement("span");
                add.className = "add";
                add.textContent = `+${counts.adds}`;
                stat.appendChild(add);
            }
            if (counts.adds > 0 && counts.dels > 0) stat.appendChild(document.createTextNode(" "));
            if (counts.dels > 0) {
                const del = document.createElement("span");
                del.className = "del";
                del.textContent = `-${counts.dels}`;
                stat.appendChild(del);
            }
            trailing.appendChild(stat);
        }
        if (file.mode && file.mode !== "modified") {
            const badge = document.createElement("span");
            badge.className = `badge ${file.mode}`;
            badge.textContent = file.mode;
            trailing.appendChild(badge);
        }
        const openTarget = file.newPath || file.oldPath;
        if (openTarget && file.mode !== "deleted") {
            const button = document.createElement("button");
            button.type = "button";
            button.className = "open-in-editor";
            button.title = "Open in VS Code";
            button.setAttribute("aria-label", "Open in VS Code");
            button.appendChild(svg("vscode"));
            button.addEventListener("click", event => {
                event.stopPropagation();
                try {
                    window.webkit.messageHandlers.orchardOpenInEditor.postMessage({ path: openTarget });
                } catch (_) {}
            });
            trailing.appendChild(button);
        }
        if (trailing.childNodes.length > 0) header.appendChild(trailing);
        section.appendChild(header);

        const body = document.createElement("div");
        body.className = "patch-file-body";
        if (file.binary || file.hunks.length === 0) {
            const notice = document.createElement("div");
            notice.className = "patch-file-notice";
            notice.textContent = file.binary ? "Binary file" : "No textual changes.";
            body.appendChild(notice);
        } else {
            const table = document.createElement("table");
            table.className = "diff-table";
            const tbody = document.createElement("tbody");
            table.appendChild(tbody);

            for (const hunk of file.hunks) {
                const hunkRow = document.createElement("tr");
                hunkRow.className = "hunk-header-row";
                const cell = document.createElement("td");
                cell.colSpan = 3;
                cell.textContent = hunk.header;
                hunkRow.appendChild(cell);
                tbody.appendChild(hunkRow);

                for (const row of hunk.rows) {
                    const tr = document.createElement("tr");
                    tr.className = `diff-row ${row.kind}`;

                    const oldNo = document.createElement("td");
                    oldNo.className = "gutter old";
                    oldNo.textContent = row.oldNo == null ? "" : String(row.oldNo);
                    tr.appendChild(oldNo);

                    const newNo = document.createElement("td");
                    newNo.className = "gutter new";
                    newNo.textContent = row.newNo == null ? "" : String(row.newNo);
                    tr.appendChild(newNo);

                    const content = document.createElement("td");
                    content.className = "content";
                    content.textContent = row.text;
                    tr.appendChild(content);

                    tbody.appendChild(tr);
                }
            }
            body.appendChild(table);
        }
        section.appendChild(body);
        toggle.addEventListener("click", () => {
            const collapsed = section.classList.toggle("collapsed");
            toggle.setAttribute("aria-expanded", collapsed ? "false" : "true");
        });
        return section;
    }

    function render(payload) {
        const diff = payload?.diff || "";
        const r = root();
        r.innerHTML = "";
        if (!diff.trim()) {
            setMessage("No diff.");
            return;
        }
        const files = parseUnifiedDiff(diff);
        if (files.length === 0) {
            setMessage(diff);
            return;
        }
        const fragment = document.createDocumentFragment();
        files.forEach((file, index) => fragment.appendChild(renderFile(file, index)));
        r.appendChild(fragment);
    }

    window.orchardRenderDiff = payload => {
        try {
            render(payload);
        } catch (error) {
            setMessage(`Failed to render diff: ${error?.message || String(error)}`);
        }
    };

    window.orchardShowError = payload => {
        setMessage(payload?.message || "Unable to render diff.");
    };

    let searchMatches = [];
    let searchIndex = -1;
    let searchQuery = "";

    function clearSearchHighlights() {
        for (const mark of document.querySelectorAll("mark.orchard-search-hit")) {
            const parent = mark.parentNode;
            if (!parent) continue;
            parent.replaceChild(document.createTextNode(mark.textContent), mark);
            parent.normalize();
        }
        searchMatches = [];
        searchIndex = -1;
    }

    function reportSearch() {
        try {
            window.webkit.messageHandlers.orchardSearchResult.postMessage({
                count: searchMatches.length,
                index: searchMatches.length ? searchIndex + 1 : 0
            });
        } catch (_) {}
    }

    function focusMatch(index) {
        if (index < 0 || index >= searchMatches.length) return;
        searchMatches.forEach(m => m.classList.remove("current"));
        const mark = searchMatches[index];
        mark.classList.add("current");
        // Reveal the match if its file section is collapsed.
        const section = mark.closest(".patch-file");
        if (section && section.classList.contains("collapsed")) {
            section.classList.remove("collapsed");
            const toggle = section.querySelector(".patch-file-toggle");
            if (toggle) toggle.setAttribute("aria-expanded", "true");
        }
        mark.scrollIntoView({ block: "center", inline: "nearest" });
    }

    function runSearch(query) {
        clearSearchHighlights();
        searchQuery = query;
        if (!query) return;

        const needle = query.toLowerCase();
        for (const cell of document.querySelectorAll(".diff-row > .content")) {
            const text = cell.textContent;
            const lower = text.toLowerCase();
            let idx = lower.indexOf(needle);
            if (idx === -1) continue;

            const fragment = document.createDocumentFragment();
            let pos = 0;
            while (idx !== -1) {
                if (idx > pos) fragment.appendChild(document.createTextNode(text.slice(pos, idx)));
                const mark = document.createElement("mark");
                mark.className = "orchard-search-hit";
                mark.textContent = text.slice(idx, idx + query.length);
                fragment.appendChild(mark);
                searchMatches.push(mark);
                pos = idx + query.length;
                idx = lower.indexOf(needle, pos);
            }
            if (pos < text.length) fragment.appendChild(document.createTextNode(text.slice(pos)));
            cell.textContent = "";
            cell.appendChild(fragment);
        }

        if (searchMatches.length > 0) {
            searchIndex = 0;
            focusMatch(searchIndex);
        }
        reportSearch();
    }

    // Re-run the whole pass for the current query (driven by typing). Resets
    // to the first match and reports the count.
    window.orchardSearch = payload => {
        const query = payload?.query || "";
        try {
            runSearch(query);
        } catch (_) {
            reportSearch();
        }
    };

    // Advance to the next match without re-scanning (driven by Enter).
    window.orchardSearchNext = () => {
        if (searchMatches.length === 0) return;
        searchIndex = (searchIndex + 1) % searchMatches.length;
        focusMatch(searchIndex);
        reportSearch();
    };

    let lastCopied = "";
    function copySelection() {
        const selection = window.getSelection();
        if (!selection || selection.isCollapsed) return;
        const text = selection.toString();
        if (!text || text === lastCopied) return;
        lastCopied = text;
        try {
            window.webkit.messageHandlers.orchardCopy.postMessage(text);
        } catch (_) {}
    }
    document.addEventListener("mouseup", copySelection);
    document.addEventListener("keyup", event => {
        if (event.shiftKey || event.key === "Shift" || event.metaKey) copySelection();
    });
})();
</script>
</body>
</html>
"""#
}

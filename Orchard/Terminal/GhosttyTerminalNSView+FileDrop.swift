import AppKit
import GhosttyKit

extension GhosttyTerminalNSView {
    // MARK: - File drops

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !draggedFileURLs(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = draggedFileURLs(from: sender)
        guard !urls.isEmpty else { return false }

        window?.makeFirstResponder(self)
        if let surface {
            ghostty_surface_set_focus(surface, true)
            onFocus?()
        }

        insertText(
            droppedFileText(for: urls),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        return true
    }

    private func dragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        draggedFileURLs(from: sender).isEmpty ? [] : .copy
    }

    private func draggedFileURLs(from sender: NSDraggingInfo) -> [URL] {
        // Only accept drags that originated outside the app (e.g. Finder).
        // Intra-app drags (sidebar project/tab reorder) have a non-nil
        // draggingSource and must not be treated as file drops — accepting
        // them produces glitchy drop highlighting over the terminal.
        guard sender.draggingSource == nil else { return [] }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return sender.draggingPasteboard
            .readObjects(forClasses: [NSURL.self], options: options)?
            .compactMap { item in
                guard let url = item as? URL, url.isFileURL else { return nil }
                return url
            } ?? []
    }

    private func droppedFileText(for urls: [URL]) -> String {
        urls.map { shellEscapedPath($0.path) }.joined(separator: " ") + " "
    }

    private func shellEscapedPath(_ path: String) -> String {
        "'\(path.split(separator: "'", omittingEmptySubsequences: false).joined(separator: "'\\''"))'"
    }
}

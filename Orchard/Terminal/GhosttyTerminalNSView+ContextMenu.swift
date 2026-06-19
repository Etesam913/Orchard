import AppKit

extension GhosttyTerminalNSView {
    // MARK: - Context menu

    func presentContextMenu(with event: NSEvent) {
        let menu = NSMenu(title: "Terminal")
        let paste = NSMenuItem(title: "Paste", action: #selector(handlePaste), keyEquivalent: "")
        paste.target = self
        paste.isEnabled = NSPasteboard.general.string(forType: .string).map { !$0.isEmpty } ?? false
        menu.addItem(paste)
        menu.addItem(.separator())
        addSplitItem(menu, "Split Right", .horizontal, .second)
        addSplitItem(menu, "Split Left", .horizontal, .first)
        addSplitItem(menu, "Split Down", .vertical, .second)
        addSplitItem(menu, "Split Up", .vertical, .first)
        if onZoomRequest != nil {
            menu.addItem(.separator())
            let zoom = NSMenuItem(
                title: isZoomed ? "Restore Pane" : "Zoom Pane",
                action: #selector(handleZoom),
                keyEquivalent: ""
            )
            zoom.target = self
            menu.addItem(zoom)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc
    private func handleZoom() {
        onZoomRequest?()
    }

    private func addSplitItem(_ menu: NSMenu, _ title: String, _ dir: SplitDirection, _ pos: SplitPosition) {
        let item = NSMenuItem(title: title, action: #selector(handleSplit(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ContextSplit(direction: dir, position: pos)
        menu.addItem(item)
    }

    @objc
    private func handlePaste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        window?.makeFirstResponder(self)
        insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @objc
    private func handleSplit(_ sender: NSMenuItem) {
        guard let split = sender.representedObject as? ContextSplit else { return }
        onSplitRequest?(split.direction, split.position)
    }

    private final class ContextSplit: NSObject {
        let direction: SplitDirection
        let position: SplitPosition
        init(direction: SplitDirection, position: SplitPosition) {
            self.direction = direction
            self.position = position
        }
    }
}

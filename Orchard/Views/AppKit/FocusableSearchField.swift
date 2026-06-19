import AppKit
import SwiftUI

/// A borderless NSTextField that can be programmatically focused. `focusTrigger`
/// is a monotonic counter; whenever it changes the field grabs first responder,
/// which is the only reliable way to focus a control living inside an NSToolbar.
struct FocusableSearchField: NSViewRepresentable {
    @Binding var text: String
    var focusTrigger: Int
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = "Search diff"
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        guard context.coordinator.lastFocusTrigger != focusTrigger else { return }
        context.coordinator.lastFocusTrigger = focusTrigger
        // Defer: on first appearance the field isn't in a window yet.
        DispatchQueue.main.async {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusableSearchField
        // Start at Int.min so the first real trigger value always differs and
        // focuses on initial appearance.
        var lastFocusTrigger = Int.min

        init(_ parent: FocusableSearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

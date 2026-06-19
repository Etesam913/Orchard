import AppKit
import Foundation

@MainActor
final class HotkeyCaptureState {
    static let shared = HotkeyCaptureState()
    var isCapturing = false
}

struct HotkeyShortcut: Identifiable {
    let id: String
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    func matches(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == modifiers
    }
}

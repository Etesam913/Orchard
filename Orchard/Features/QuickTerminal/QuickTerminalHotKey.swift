import AppKit
import Carbon

/// Carbon global hot-key registration for the quick terminal toggle.
@MainActor
extension QuickTerminalService {
    func registerHotKey() {
        // Idempotent: skip if already registered. Without this, toggling the
        // preference repeatedly would leak event handlers and double-fire.
        guard carbonHotKeyRef == nil else { return }
        guard let shortcut = HotkeyRegistry.selectedShortcut(for: .toggleQuickTerminal) else {
            // User cleared the binding — nothing to register. The shortcut
            // is also unavailable in-app; toggling via the palette or menu
            // command still works.
            return
        }

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x4D55_5859)
        hotKeyID.id = 1

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &id
            )
            if id.id == 1 {
                let svc = Unmanaged<QuickTerminalService>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { svc.toggle() }
            }
            return noErr
        }, 1, &spec, selfPtr, &carbonEventHandler)

        RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            Self.carbonModifiers(from: shortcut.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &carbonHotKeyRef
        )
        lastRegisteredShortcutID = shortcut.id
    }

    /// Translate Cocoa modifier flags to Carbon's bitmask. Carbon's hot-key
    /// API predates Cocoa and uses its own constants.
    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        return mods
    }

    func unregisterHotKey() {
        if let ref = carbonHotKeyRef {
            UnregisterEventHotKey(ref)
            carbonHotKeyRef = nil
        }
        if let handler = carbonEventHandler {
            RemoveEventHandler(handler)
            carbonEventHandler = nil
        }
        lastRegisteredShortcutID = nil
    }
}

import AppKit
import GhosttyKit

extension GhosttyTerminalNSView {
    // MARK: - App shortcut detection

    /// System shortcuts that should always pass through to macOS.
    private static let systemKeys: Set<String> = ["q", "h", "m", ","]

    private func isAppShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        // Always let system Cmd shortcuts through
        if flags == .command, Self.systemKeys.contains(key) { return true }
        // Cmd+1-9 for tab selection
        if flags == .command, let n = Int(key), (1 ... 9).contains(n) { return true }
        // Check all configurable hotkey actions. `focusDiffSearch` (Cmd+F) is
        // deliberately excluded: a focused terminal owns Cmd+F for its own
        // search, so we forward it to Ghostty instead of swallowing it as an
        // app shortcut. (The KeyRouter only routes Cmd+F to the diff search
        // when a terminal pane isn't first responder.)
        if AppCommand.allCases.contains(where: {
            $0 != .focusDiffSearch && HotkeyRegistry.matches(event, command: $0)
        }) { return true }
        return false
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else { super.keyDown(with: event)
            return
        }
        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !event.isARepeat {
            trackCommandInput(event)
        }

        if flags.contains(.control), !flags.contains(.command), !flags.contains(.option), !hasMarkedText() {
            if isAppShortcut(event) { return }
            var ke = buildKeyEvent(from: event, action: action)
            let text = event.charactersIgnoringModifiers ?? event.characters ?? ""
            if text.isEmpty {
                ke.text = nil
                _ = ghostty_surface_key(surface, ke)
            } else {
                text.withCString { ke.text = $0
                    _ = ghostty_surface_key(surface, ke)
                }
            }
            return
        }

        if flags.contains(.command) {
            if isAppShortcut(event) { return }
            var ke = buildKeyEvent(from: event, action: action)
            ke.text = nil
            _ = ghostty_surface_key(surface, ke)
            return
        }

        let hadMarkedText = hasMarkedText()
        currentKeyEvent = event
        keyTextAccumulator = []
        // Ask libghostty which modifier flags to use for *translation* — when
        // macos-option-as-alt is on, it returns flags with Option stripped.
        // We then build a synthetic NSEvent whose `characters` come from
        // `characters(byApplyingModifiers:)` with those flags, so Option+b
        // yields "b" instead of "∫" when routed through interpretKeyEvents.
        let translationEvent = translatedEvent(for: event)
        interpretKeyEvents([translationEvent])
        currentKeyEvent = nil

        var ke = buildKeyEvent(from: event, action: action)
        // consumed_mods tells libghostty which modifiers were "used up" to
        // produce the translated text. We use the translation event's flags
        // (Alt stripped when option-as-alt is on), minus ctrl/command which
        // never contribute to text translation. This matches Ghostty's own
        // app: with option-as-alt on, Alt is *not* consumed, so libghostty
        // encodes ESC+b for Option+b, letting editors like Helix see it.
        ke.consumed_mods = consumedMods(translationEvent.modifierFlags)
        ke.composing = hasMarkedText() || hadMarkedText

        // Accumulator content is text the IME *committed* via `insertText`
        // during interpretKeyEvents. Send it regardless of `composing` state:
        // committing happens precisely when the IME finishes a syllable, which
        // may overlap with a new composition starting (so `composing == true`
        // here even though this specific text is finalized). Without this,
        // Korean / Japanese / Chinese input drops every committed character.
        // The text itself carries no composing flag since it's already final.
        if !keyTextAccumulator.isEmpty {
            var commitKE = ke
            commitKE.composing = false
            for text in keyTextAccumulator {
                text.withCString { commitKE.text = $0
                    _ = ghostty_surface_key(surface, commitKE)
                }
            }
        } else if !hasMarkedText() {
            let text = filterSpecial(event.characters ?? "")
            if !text.isEmpty, !ke.composing {
                text.withCString { ke.text = $0
                    _ = ghostty_surface_key(surface, ke)
                }
            } else {
                ke.consumed_mods = GHOSTTY_MODS_NONE
                ke.text = nil
                _ = ghostty_surface_key(surface, ke)
            }
        }
    }

    override func doCommand(by selector: Selector) {}

    override func insertText(_ insertString: Any) {
        insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        var ke = buildKeyEvent(from: event, action: GHOSTTY_ACTION_RELEASE)
        ke.text = nil
        _ = ghostty_surface_key(surface, ke)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }
        var ke = buildKeyEvent(from: event, action: isFlagPress(event) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE)
        ke.text = nil
        _ = ghostty_surface_key(surface, ke)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isAppShortcut(event) { return false }
        guard window?.firstResponder === self || window?.firstResponder === inputContext else { return false }
        guard event.type == .keyDown, let surface else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else { return false }
        var ke = buildKeyEvent(from: event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
        ke.text = nil
        if ghostty_surface_key_is_binding(surface, ke, nil) {
            _ = ghostty_surface_key(surface, ke)
            return true
        }
        return false
    }

    // MARK: - Key event helpers

    private func buildKeyEvent(from event: NSEvent, action: ghostty_input_action_e) -> ghostty_input_key_s {
        var ke = ghostty_input_key_s()
        ke.action = action
        ke.keycode = UInt32(event.keyCode)
        ke.mods = mods(event)
        ke.consumed_mods = GHOSTTY_MODS_NONE
        ke.composing = false
        ke.text = nil
        ke.unshifted_codepoint = unshiftedCodepoint(from: event)
        return ke
    }

    private func consumedMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        // ctrl/command never contribute to text translation; assume everything
        // else did. Matches Ghostty's own app behavior.
        var m = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: m)
    }

    func mods(_ event: NSEvent) -> ghostty_input_mods_e {
        var m = GHOSTTY_MODS_NONE.rawValue
        let f = event.modifierFlags
        if f.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if f.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if f.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if f.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if f.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: m)
    }

    private func isFlagPress(_ event: NSEvent) -> Bool {
        let f = event.modifierFlags
        switch event.keyCode {
        case 56,
             60: return f.contains(.shift)
        case 58,
             61: return f.contains(.option)
        case 59,
             62: return f.contains(.control)
        case 55,
             54: return f.contains(.command)
        case 57: return f.contains(.capsLock)
        default: return false
        }
    }

    private func filterSpecial(_ text: String) -> String {
        guard let scalar = text.unicodeScalars.first else { return "" }
        let v = scalar.value
        if v < 0x20 || (0xF700 ... 0xF8FF).contains(v) { return "" }
        return text
    }

    private func trackCommandInput(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.option) { return }
        if flags.contains(.control) {
            let key = (event.charactersIgnoringModifiers ?? "").lowercased()
            if key == "c" || key == "d" { commandLineBuffer = "" }
            return
        }

        switch event.keyCode {
        case 36, 76:
            let command = commandLineBuffer
            commandLineBuffer = ""
            onCommandSubmitted?(command)
        case 51:
            if !commandLineBuffer.isEmpty { commandLineBuffer.removeLast() }
        default:
            let text = filterSpecial(event.characters ?? "")
            if text.contains("\n") || text.contains("\r") {
                let parts = text.components(separatedBy: .newlines)
                if let first = parts.first {
                    commandLineBuffer += first
                    onCommandSubmitted?(commandLineBuffer)
                }
                commandLineBuffer = parts.last ?? ""
            } else {
                commandLineBuffer += text
            }
        }
    }

    /// Builds a synthetic NSEvent whose modifier flags reflect libghostty's
    /// translation policy — with macos-option-as-alt on, Option is stripped so
    /// `characters(byApplyingModifiers:)` returns the unshifted char ("b")
    /// instead of the macOS special char ("∫"). Falls back to the original
    /// event if no rewrite is needed or if NSEvent.keyEvent fails.
    private func translatedEvent(for event: NSEvent) -> NSEvent {
        guard let surface else { return event }
        let originalMods = mods(event)
        let translationModsRaw = ghostty_surface_key_translation_mods(surface, originalMods).rawValue
        var translationFlags = event.modifierFlags
        for (bit, flag) in [
            (GHOSTTY_MODS_SHIFT.rawValue, NSEvent.ModifierFlags.shift),
            (GHOSTTY_MODS_CTRL.rawValue, NSEvent.ModifierFlags.control),
            (GHOSTTY_MODS_ALT.rawValue, NSEvent.ModifierFlags.option),
            (GHOSTTY_MODS_SUPER.rawValue, NSEvent.ModifierFlags.command),
        ] {
            if translationModsRaw & bit != 0 { translationFlags.insert(flag) } else { translationFlags.remove(flag) }
        }
        if translationFlags == event.modifierFlags { return event }
        let translatedChars = event.characters(byApplyingModifiers: translationFlags) ?? ""
        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: translationFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: translatedChars,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) ?? event
    }

    private func unshiftedCodepoint(from event: NSEvent) -> UInt32 {
        // `characters(byApplyingModifiers:)` raises NSInternalInconsistencyException
        // on non-key events. flagsChanged routes through buildKeyEvent too, so
        // we must guard the event type here or the modifier-key release/press
        // tears the app down.
        guard event.type == .keyDown || event.type == .keyUp else { return 0 }
        guard let chars = event.characters(byApplyingModifiers: []),
              let scalar = chars.unicodeScalars.first
        else { return 0 }
        return scalar.value
    }
}

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

enum HotkeyRegistry {
    private static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5,
        "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "enter": 36,
        "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "tab": 48, "space": 49, "`": 50,
    ]
    private static let modifierOnlyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62]

    private static let keyTokensByCode: [UInt16: String] = {
        var map: [UInt16: String] = [:]
        for (token, code) in keyCodes where map[code] == nil {
            map[code] = token
        }
        return map
    }()

    static func parseShortcut(_ raw: String) -> HotkeyShortcut? {
        let cleaned = raw.lowercased().replacingOccurrences(of: " ", with: "")
        if cleaned.isEmpty || cleaned == "none" || cleaned == "disabled" {
            return nil
        }

        let tokens = cleaned.split(separator: "+").map(String.init)
        guard let keyToken = tokens.last, let keyCode = keyCodes[keyToken] else {
            return nil
        }

        var modifiers: NSEvent.ModifierFlags = []
        for token in tokens.dropLast() {
            switch token {
            case "cmd",
                 "command",
                 "⌘": modifiers.insert(.command)
            case "ctrl",
                 "control",
                 "⌃": modifiers.insert(.control)
            case "shift",
                 "⇧": modifiers.insert(.shift)
            case "opt",
                 "option",
                 "alt",
                 "⌥": modifiers.insert(.option)
            default: return nil
            }
        }

        return HotkeyShortcut(id: cleaned, keyCode: keyCode, modifiers: modifiers)
    }

    static func shortcutString(from event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifierOnlyCodes.contains(event.keyCode) { return nil }

        var parts: [String] = []
        if flags.contains(.command) { parts.append("cmd") }
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.option) { parts.append("opt") }
        guard !parts.isEmpty else { return nil }

        guard let keyToken = keyTokensByCode[event.keyCode] else { return nil }
        parts.append(keyToken)
        return parts.joined(separator: "+")
    }

    static func displayString(for shortcut: String) -> String {
        let cleaned = shortcut.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned.isEmpty || cleaned == "disabled" || cleaned == "none" {
            return "Disabled"
        }

        let tokens = cleaned.split(separator: "+").map(String.init)
        guard !tokens.isEmpty else { return "Disabled" }

        var out = ""
        for token in tokens.dropLast() {
            switch token {
            case "cmd",
                 "command": out += "⌘"
            case "ctrl",
                 "control": out += "⌃"
            case "shift": out += "⇧"
            case "opt",
                 "option",
                 "alt": out += "⌥"
            default: break
            }
        }

        let key = tokens.last ?? ""
        let keyLabel: String = switch key {
        case "tab": "Tab"
        case "space": "Space"
        case "return",
             "enter": "↩"
        default: key.uppercased()
        }
        return out + keyLabel
    }

    static func selectedShortcutString(for command: AppCommand) -> String {
        UserDefaults.standard.string(forKey: command.defaultsKey) ?? (command.defaultShortcut ?? "")
    }

    static func selectedShortcut(for command: AppCommand) -> HotkeyShortcut? {
        parseShortcut(selectedShortcutString(for: command))
            ?? command.defaultShortcut.flatMap(parseShortcut)
    }

    static func setShortcutString(_ shortcut: String, for command: AppCommand) {
        UserDefaults.standard.set(shortcut, forKey: command.defaultsKey)
    }

    static func isValidShortcutString(_ shortcut: String) -> Bool {
        let cleaned = shortcut.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned.isEmpty || cleaned == "none" || cleaned == "disabled" {
            return true
        }
        return parseShortcut(cleaned) != nil
    }

    static func matches(_ event: NSEvent, command: AppCommand) -> Bool {
        guard let shortcut = selectedShortcut(for: command), shortcut.id != "none" else { return false }
        return shortcut.matches(event)
    }
}

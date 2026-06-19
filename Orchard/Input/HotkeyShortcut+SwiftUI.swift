import SwiftUI

extension HotkeyShortcut {
    /// Maps the parsed keyCode back to a SwiftUI-renderable KeyEquivalent.
    /// Returns nil for keys we don't have a mapping for (rare — covers the
    /// keys used in default bindings).
    var menuKeyEquivalent: KeyEquivalent? {
        switch keyCode {
        case 36: .return
        case 48: .tab
        case 49: .space
        case 50: "`"
        case 24: "="
        case 27: "-"
        case 30: "]"
        case 33: "["
        case 41: ";"
        case 39: "'"
        case 42: "\\"
        case 43: ","
        case 44: "/"
        case 47: "."
        default:
            // Letters and digits round-trip through Self.charForCode.
            HotkeyShortcut.letterOrDigit(for: keyCode).map { KeyEquivalent($0) }
        }
    }

    var menuModifiers: EventModifiers {
        var out: EventModifiers = []
        if modifiers.contains(.command) { out.insert(.command) }
        if modifiers.contains(.control) { out.insert(.control) }
        if modifiers.contains(.shift) { out.insert(.shift) }
        if modifiers.contains(.option) { out.insert(.option) }
        return out
    }

    private static let codeToChar: [UInt16: Character] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g",
        6: "z", 7: "x", 8: "c", 9: "v", 11: "b",
        12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        25: "9", 26: "7", 28: "8", 29: "0",
        31: "o", 32: "u", 34: "i", 35: "p",
        37: "l", 38: "j", 40: "k",
        45: "n", 46: "m",
    ]

    static func letterOrDigit(for code: UInt16) -> Character? { codeToChar[code] }
}

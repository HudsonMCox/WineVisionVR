import Foundation

/// US-layout virtual keys for the existing Wine key-event bridge.
public enum WindowsDesktopKeyboard {
    public static func virtualKey(hidUsage: Int) -> Int32? {
        switch hidUsage {
        case 0x04...0x1D: Int32(0x41 + hidUsage - 0x04)
        case 0x1E...0x26: Int32(0x31 + hidUsage - 0x1E)
        case 0x27: 0x30
        case 0x28: 0x0D
        case 0x29: 0x1B
        case 0x2A: 0x08
        case 0x2B: 0x09
        case 0x2C: 0x20
        case 0x2D: 0xBD
        case 0x2E: 0xBB
        case 0x2F: 0xDB
        case 0x30: 0xDD
        case 0x31, 0x32: 0xDC
        case 0x33: 0xBA
        case 0x34: 0xDE
        case 0x35: 0xC0
        case 0x36: 0xBC
        case 0x37: 0xBE
        case 0x38: 0xBF
        case 0x39: 0x14
        case 0x3A...0x45: Int32(0x70 + hidUsage - 0x3A)
        case 0x49: 0x2D
        case 0x4A: 0x24
        case 0x4B: 0x21
        case 0x4C: 0x2E
        case 0x4D: 0x23
        case 0x4E: 0x22
        case 0x4F: 0x27
        case 0x50: 0x25
        case 0x51: 0x28
        case 0x52: 0x26
        case 0xE0: 0xA2
        case 0xE1: 0xA0
        case 0xE2: 0xA4
        case 0xE3: 0x5B
        case 0xE4: 0xA3
        case 0xE5: 0xA1
        case 0xE6: 0xA5
        case 0xE7: 0x5C
        default: nil
        }
    }

    public static func stroke(for character: Character) -> (key: Int32, shift: Bool)? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case 65...90: return (Int32(ascii), true)
        case 97...122: return (Int32(ascii - 32), false)
        case 48...57: return (Int32(ascii), false)
        case 9: return (0x09, false)
        case 10, 13: return (0x0D, false)
        case 32: return (0x20, false)
        default: return symbols[character]
        }
    }

    private static let symbols: [Character: (Int32, Bool)] = [
        "!": (0x31, true), "@": (0x32, true), "#": (0x33, true), "$": (0x34, true),
        "%": (0x35, true), "^": (0x36, true), "&": (0x37, true), "*": (0x38, true),
        "(": (0x39, true), ")": (0x30, true), "-": (0xBD, false), "_": (0xBD, true),
        "=": (0xBB, false), "+": (0xBB, true), "[": (0xDB, false), "{": (0xDB, true),
        "]": (0xDD, false), "}": (0xDD, true), "\\": (0xDC, false), "|": (0xDC, true),
        ";": (0xBA, false), ":": (0xBA, true), "'": (0xDE, false), "\"": (0xDE, true),
        ",": (0xBC, false), "<": (0xBC, true), ".": (0xBE, false), ">": (0xBE, true),
        "/": (0xBF, false), "?": (0xBF, true), "`": (0xC0, false), "~": (0xC0, true)
    ]
}

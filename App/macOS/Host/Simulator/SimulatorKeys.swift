import Foundation

/// Text, key names and Mac keys as USB HID keyboard usages, on a US layout.
nonisolated enum SimulatorKeys {
    struct Stroke {
        let usage: UInt32
        let shift: Bool
    }

    static let control: UInt32 = 0xE0
    static let shift: UInt32 = 0xE1
    static let option: UInt32 = 0xE2
    static let command: UInt32 = 0xE3
    static let returnKey: UInt32 = 0x28
    static let v: UInt32 = 0x19
    static let capsLock: UInt32 = 0x39

    /// The keys that type `text`, or nil when a character isn't on a US keyboard.
    static func strokes(for text: String) -> [Stroke]? {
        var strokes: [Stroke] = []
        for character in text {
            guard let stroke = stroke(for: character) else { return nil }
            strokes.append(stroke)
        }
        return strokes
    }

    static func usage(named name: String) -> Stroke? {
        switch name.lowercased() {
        case "return", "enter": Stroke(usage: returnKey, shift: false)
        case "escape", "esc": Stroke(usage: 0x29, shift: false)
        case "delete", "backspace": Stroke(usage: 0x2A, shift: false)
        case "tab": Stroke(usage: 0x2B, shift: false)
        case "space": Stroke(usage: 0x2C, shift: false)
        case "right": Stroke(usage: 0x4F, shift: false)
        case "left": Stroke(usage: 0x50, shift: false)
        case "down": Stroke(usage: 0x51, shift: false)
        case "up": Stroke(usage: 0x52, shift: false)
        default: name.count == 1 ? stroke(for: Character(name)) : nil
        }
    }

    static func modifierUsage(_ name: String) -> UInt32? {
        switch name.lowercased() {
        case "control", "ctrl": control
        case "shift": shift
        case "option", "alt": option
        case "command", "cmd", "meta": command
        default: nil
        }
    }

    /// The usage for a Mac key code, as `NSEvent.keyCode` gives it.
    static func usage(forMacKey keyCode: UInt16) -> UInt32? {
        macKeys[keyCode]
    }

    /// Presses a key with modifiers held, then lets them all go.
    static func press(_ usage: UInt32, modifiers: [UInt32] = [], on input: SimulatorInput) async {
        for modifier in modifiers { input.key(modifier, down: true) }
        input.key(usage, down: true)
        input.key(usage, down: false)
        for modifier in modifiers.reversed() { input.key(modifier, down: false) }
        await input.flush()
        // Lets iOS take each key before the next, as a fast typist's would.
        try? await Task.sleep(for: .milliseconds(12))
    }

    private static func stroke(for character: Character) -> Stroke? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return character == "\r\n" ? Stroke(usage: returnKey, shift: false) : nil
        }
        switch scalar {
        case "a"..."z": return Stroke(usage: 0x04 + scalar.value - 97, shift: false)
        case "A"..."Z": return Stroke(usage: 0x04 + scalar.value - 65, shift: true)
        case "1"..."9": return Stroke(usage: 0x1E + scalar.value - 49, shift: false)
        case "0": return Stroke(usage: 0x27, shift: false)
        default: break
        }
        let table: [Character: (UInt32, Bool)] = [
            "\n": (returnKey, false), "\t": (0x2B, false), " ": (0x2C, false),
            "-": (0x2D, false), "_": (0x2D, true), "=": (0x2E, false), "+": (0x2E, true),
            "[": (0x2F, false), "{": (0x2F, true), "]": (0x30, false), "}": (0x30, true),
            "\\": (0x31, false), "|": (0x31, true), ";": (0x33, false), ":": (0x33, true),
            "'": (0x34, false), "\"": (0x34, true), "`": (0x35, false), "~": (0x35, true),
            ",": (0x36, false), "<": (0x36, true), ".": (0x37, false), ">": (0x37, true),
            "/": (0x38, false), "?": (0x38, true),
            "!": (0x1E, true), "@": (0x1F, true), "#": (0x20, true), "$": (0x21, true), "%": (0x22, true),
            "^": (0x23, true), "&": (0x24, true), "*": (0x25, true), "(": (0x26, true), ")": (0x27, true),
        ]
        return table[character].map { Stroke(usage: $0.0, shift: $0.1) }
    }

    private static let macKeys: [UInt16: UInt32] = [
        0x00: 0x04, 0x0B: 0x05, 0x08: 0x06, 0x02: 0x07, 0x0E: 0x08, 0x03: 0x09, 0x05: 0x0A, 0x04: 0x0B, // a b c d e f g h
        0x22: 0x0C, 0x26: 0x0D, 0x28: 0x0E, 0x25: 0x0F, 0x2E: 0x10, 0x2D: 0x11, 0x1F: 0x12, 0x23: 0x13, // i j k l m n o p
        0x0C: 0x14, 0x0F: 0x15, 0x01: 0x16, 0x11: 0x17, 0x20: 0x18, 0x09: 0x19, 0x0D: 0x1A, 0x07: 0x1B, // q r s t u v w x
        0x10: 0x1C, 0x06: 0x1D,                                                                         // y z
        0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, 0x17: 0x22, 0x16: 0x23, 0x1A: 0x24, 0x1C: 0x25, // 1-8
        0x19: 0x26, 0x1D: 0x27,                                                                         // 9 0
        0x24: 0x28, 0x35: 0x29, 0x33: 0x2A, 0x30: 0x2B, 0x31: 0x2C,                                     // return esc delete tab space
        0x1B: 0x2D, 0x18: 0x2E, 0x21: 0x2F, 0x1E: 0x30, 0x2A: 0x31, 0x29: 0x33, 0x27: 0x34, 0x32: 0x35, // - = [ ] \ ; ' `
        0x2B: 0x36, 0x2F: 0x37, 0x2C: 0x38, 0x39: 0x39, 0x0A: 0x64,                                     // , . / caps §
        0x7A: 0x3A, 0x78: 0x3B, 0x63: 0x3C, 0x76: 0x3D, 0x60: 0x3E, 0x61: 0x3F, 0x62: 0x40, 0x64: 0x41, // F1-F8
        0x65: 0x42, 0x6D: 0x43, 0x67: 0x44, 0x6F: 0x45,                                                 // F9-F12
        0x73: 0x4A, 0x74: 0x4B, 0x75: 0x4C, 0x77: 0x4D, 0x79: 0x4E,                                     // home pgup fwd-del end pgdn
        0x7C: 0x4F, 0x7B: 0x50, 0x7D: 0x51, 0x7E: 0x52,                                                 // arrows
        0x47: 0x53, 0x4B: 0x54, 0x43: 0x55, 0x4E: 0x56, 0x45: 0x57, 0x4C: 0x58, 0x53: 0x59, 0x54: 0x5A, // keypad
        0x55: 0x5B, 0x56: 0x5C, 0x57: 0x5D, 0x58: 0x5E, 0x59: 0x5F, 0x5B: 0x60, 0x5C: 0x61, 0x52: 0x62,
        0x41: 0x63, 0x51: 0x67,
        0x3B: 0xE0, 0x38: 0xE1, 0x3A: 0xE2, 0x37: 0xE3, 0x3E: 0xE4, 0x3C: 0xE5, 0x3D: 0xE6, 0x36: 0xE7, // modifiers
    ]
}

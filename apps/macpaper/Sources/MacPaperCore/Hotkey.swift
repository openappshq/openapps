import Foundation

/// A global keyboard shortcut: a virtual key code and modifiers, as Carbon's
/// `RegisterEventHotKey` takes them. Stored as JSON in the preferences.
public struct Hotkey: Codable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)

        /// Carbon's `cmdKey`, `optionKey`, `controlKey`, `shiftKey`.
        public var carbonFlags: UInt32 {
            var flags: UInt32 = 0
            if contains(.command) { flags |= 1 << 8 }
            if contains(.shift) { flags |= 1 << 9 }
            if contains(.option) { flags |= 1 << 11 }
            if contains(.control) { flags |= 1 << 12 }
            return flags
        }

        /// In the order macOS draws them: ⌃ ⌥ ⇧ ⌘.
        public var symbols: String {
            var text = ""
            if contains(.control) { text += "⌃" }
            if contains(.option) { text += "⌥" }
            if contains(.shift) { text += "⇧" }
            if contains(.command) { text += "⌘" }
            return text
        }
    }

    public var keyCode: UInt16
    public var modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⌃⌥⌘W.
    public static let `default` = Hotkey(keyCode: 13, modifiers: [.control, .option, .command])

    /// A hotkey needs at least one of ⌘, ⌥ or ⌃ (⇧ alone would take a
    /// letter from every app), and a key that is not a modifier.
    public var isValid: Bool {
        !modifiers.isDisjoint(with: [.command, .option, .control]) && Self.keyName(keyCode) != nil
    }

    public var displayString: String {
        modifiers.symbols + (Self.keyName(keyCode) ?? "?")
    }

    /// The name of a virtual key on the ANSI layout: letters, digits and
    /// the common punctuation and function keys. Nil for modifiers and
    /// keys without a stable name.
    public static func keyName(_ keyCode: UInt16) -> String? {
        keyNames[keyCode]
    }

    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 107: "F14", 109: "F10", 111: "F12",
        113: "F15", 115: "↖", 116: "⇞", 117: "⌦", 118: "F4", 119: "↘", 120: "F2", 121: "⇟", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

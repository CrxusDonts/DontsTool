import Foundation

public enum HotKeyFormatter {
    private static let modifierSymbols: [(UInt32, String)] = [
        (SettingsStore.HotKeyConfiguration.Modifier.control.rawValue, "⌃"),
        (SettingsStore.HotKeyConfiguration.Modifier.option.rawValue, "⌥"),
        (SettingsStore.HotKeyConfiguration.Modifier.shift.rawValue, "⇧"),
        (SettingsStore.HotKeyConfiguration.Modifier.command.rawValue, "⌘")
    ]

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 109: "F10", 111: "F12", 115: "Home", 116: "PageUp",
        117: "ForwardDelete", 118: "F4", 119: "End", 120: "F2", 121: "PageDown", 122: "F1"
    ]

    public static func displayString(for configuration: SettingsStore.HotKeyConfiguration) -> String {
        if configuration.kind == .doubleTap {
            guard let modifier = configuration.doubleTapModifier,
                  let symbol = modifierSymbols.first(where: { $0.0 == modifier.rawValue })?.1 else {
                return "双击 ?"
            }
            return symbol + symbol
        }

        let modifiers = modifierSymbols
            .filter { configuration.modifiers & $0.0 != 0 }
            .map(\.1)
            .joined()
        let key = keyNames[configuration.keyCode] ?? "Key\(configuration.keyCode)"
        let separator = !modifiers.isEmpty && key.count > 1 && !key.hasPrefix("F") ? " " : ""
        return modifiers + separator + key
    }
}

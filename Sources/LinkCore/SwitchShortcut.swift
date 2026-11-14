import Foundation

/// Platform-independent physical key and the four configurable shortcut modifiers.
public struct SwitchShortcut: Equatable {
    public static let control = 1
    public static let option = 2
    public static let shift = 4
    public static let command = 8
    public static let defaultShortcut = SwitchShortcut(keyCode: 100, modifiers: control | option)
    public static let emergency = SwitchShortcut(keyCode: 53, modifiers: control | option)
    public let keyCode: UInt16
    public let modifiers: Int
    public init(keyCode: UInt16, modifiers: Int) { self.keyCode = keyCode; self.modifiers = modifiers }
    public func matches(keyCode: UInt16, modifiers: Int) -> Bool {
        self.keyCode == keyCode && self.modifiers == modifiers
    }
    public func validate() throws {
        guard keyCode <= 127, ![54,55,56,57,58,59,60,61,62,63].contains(keyCode), (0...15).contains(modifiers) else {
            throw LinkError.invalid("Choose a regular key with modifiers, or a function key.")
        }
        guard self != Self.emergency else {
            throw LinkError.invalid("Control–Option–Escape is reserved for emergency return. Choose another shortcut.")
        }
        let functionKeys: Set<UInt16> = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
        guard functionKeys.contains(keyCode) || modifiers & (Self.control | Self.option | Self.command) != 0 else {
            throw LinkError.invalid("Include Control, Option or Command so ordinary typing remains available. Function keys can be used on their own.")
        }
    }
    public var modifierLabel: String {
        [(Self.control, "Control"), (Self.option, "Option"), (Self.shift, "Shift"), (Self.command, "Command")]
            .compactMap { modifiers & $0.0 != 0 ? $0.1 : nil }.joined(separator: "–")
    }
}

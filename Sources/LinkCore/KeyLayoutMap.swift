import Foundation

/// A physical key plus the Shift/Option state that produces a character on a keyboard layout.
public struct KeyChord: Equatable {
    public let keyCode: UInt16
    public let shift: Bool
    public let option: Bool
    public init(keyCode: UInt16, shift: Bool, option: Bool) { self.keyCode = keyCode; self.shift = shift; self.option = option }
}

/// Maps characters to keys on the receiving Mac's keyboard layout, so a key typed on the keyboard
/// Mac produces the same character (and the same shortcut letter) on the other Mac even when their
/// layouts differ, for example QWERTY and QWERTZ.
public struct KeyLayoutMap {
    /// Numeric keypad keys also produce digits and symbols; they are used only when nothing else does.
    public static let keypadCodes: Set<UInt16> = [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
    private var forward: [Int: String] = [:]
    private var reverse: [String: [KeyChord]] = [:]

    /// `translate` returns the text a key produces with the given Shift and Option state, or nil.
    public init(translate: (UInt16, Bool, Bool) -> String?) {
        for code in UInt16(0)..<128 {
            for (shift, option) in [(false, false), (true, false), (false, true), (true, true)] {
                guard let text = translate(code, shift, option), Self.isPrintable(text) else { continue }
                forward[Self.index(code, shift, option)] = text
                reverse[text, default: []].append(KeyChord(keyCode: code, shift: shift, option: option))
            }
        }
    }

    /// Ordinary visible text: no control characters, no function-key codes, at most four scalars.
    public static func isPrintable(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        return !scalars.isEmpty && scalars.count <= 4 && scalars.allSatisfy {
            $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value)
        }
    }

    /// The key that types `text` on this layout. The original key and modifiers are kept when they
    /// already produce it; otherwise the closest match is chosen (same modifiers, then fewest changes,
    /// avoiding the keypad). Nil when the layout cannot type `text` at all.
    public func resolve(_ text: String, original: UInt16, shift: Bool, option: Bool) -> KeyChord? {
        if forward[Self.index(original, shift, option)] == text {
            return KeyChord(keyCode: original, shift: shift, option: option)
        }
        return reverse[text]?.min { a, b in
            let (ca, cb) = (cost(a, shift: shift, option: option), cost(b, shift: shift, option: option))
            return ca != cb ? ca < cb : a.keyCode < b.keyCode
        }
    }

    private func cost(_ chord: KeyChord, shift: Bool, option: Bool) -> Int {
        (Self.keypadCodes.contains(chord.keyCode) ? 10 : 0) + (chord.shift != shift ? 1 : 0) + (chord.option != option ? 2 : 0)
    }
    private static func index(_ code: UInt16, _ shift: Bool, _ option: Bool) -> Int {
        Int(code) << 2 | (shift ? 1 : 0) | (option ? 2 : 0)
    }
}

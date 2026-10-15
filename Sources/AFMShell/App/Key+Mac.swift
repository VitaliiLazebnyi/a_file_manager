import AFMKernel
import AppKit

/// The kernel's keys as the Mac's key codes and menu keys.
extension Key {
    /// The key codes of the named keys other than the function keys.
    private static let keyCodes: [Key: UInt16] = [
        .returnKey: 36, .enter: 76, .tab: 48, .space: 49, .backspace: 51, .forwardDelete: 117, .insert: 114,
        .home: 115, .end: 119, .pageUp: 116, .pageDown: 121, .leftArrow: 123, .rightArrow: 124, .downArrow: 125,
        .upArrow: 126, .keypadPlus: 69, .keypadMinus: 78, .keypadMultiply: 67, .keypadDivide: 75
    ]
    /// The key codes of F1 to F12, in order.
    private static let functionKeyCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    /// Every named key by its key code.
    private static let namedKeys: [UInt16: Key] = {
        var keys = Dictionary(uniqueKeysWithValues: keyCodes.map { ($0.value, $0.key) })
        for (index, code) in functionKeyCodes.enumerated() {
            keys[code] = .function(index + 1)
        }
        return keys
    }()
    /// The menu keys of the named keys a menu can show, other than the function keys.
    private static let menuKeys: [Key: String] = [
        .returnKey: "\r", .tab: "\t", .backspace: "\u{8}", .forwardDelete: functionKey(NSDeleteFunctionKey),
        .home: functionKey(NSHomeFunctionKey), .end: functionKey(NSEndFunctionKey),
        .pageUp: functionKey(NSPageUpFunctionKey), .pageDown: functionKey(NSPageDownFunctionKey),
        .leftArrow: functionKey(NSLeftArrowFunctionKey), .rightArrow: functionKey(NSRightArrowFunctionKey),
        .upArrow: functionKey(NSUpArrowFunctionKey), .downArrow: functionKey(NSDownArrowFunctionKey)
    ]

    /// The key as a menu key equivalent; nil for keys a menu cannot show (the numeric keypad).
    internal var menuEquivalent: String? {
        switch self {
        case .character(let character):
            return character

        case .function(let number):
            return Self.functionKey(NSF1FunctionKey + number - 1)

        default:
            return Self.menuKeys[self]
        }
    }

    /// The named key a physical key stands for; nil for keys that produce characters.
    internal init?(keyCode: UInt16) {
        guard let key = Self.namedKeys[keyCode] else {
            return nil
        }
        self = key
    }

    /// The character AppKit uses for one of its function keys (`NSF1FunctionKey`, the arrows).
    private static func functionKey(_ code: Int) -> String {
        String(utf16CodeUnits: [unichar(code)], count: 1)
    }
}

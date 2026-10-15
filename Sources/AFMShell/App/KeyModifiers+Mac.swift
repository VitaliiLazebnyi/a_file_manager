import AFMKernel
import AppKit

/// The kernel's modifiers as the Mac's modifier flags.
extension KeyModifiers {
    /// Each modifier with its flag.
    private static let flagPairs: [(modifier: KeyModifiers, flag: NSEvent.ModifierFlags)] = [
        (.shift, .shift), (.control, .control), (.option, .option), (.command, .command)
    ]

    /// The modifiers as a key event or a menu item has them.
    internal var eventFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(Self.flagPairs.filter { contains($0.modifier) }.map(\.flag))
    }

    /// The modifiers among `flags`; the other flags (Caps Lock, the numeric keypad) are left out.
    internal init(_ flags: NSEvent.ModifierFlags) {
        self.init(Self.flagPairs.filter { flags.contains($0.flag) }.map(\.modifier))
    }
}

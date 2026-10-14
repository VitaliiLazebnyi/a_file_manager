import Foundation

/// The keys held down with the key of a shortcut.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    /// Shift.
    public static let shift = Self(rawValue: 1)
    /// Control.
    public static let control = Self(rawValue: 2)
    /// Option.
    public static let option = Self(rawValue: 4)
    /// Command.
    public static let command = Self(rawValue: 8)

    /// The bits of the keys held down.
    public let rawValue: Int

    /// The modifiers whose bits are set in `rawValue`.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

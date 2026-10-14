import Foundation

/// The name of a command.
///
/// Plugins register commands under names; menus, keys and other plugins refer to them by name only. The kernel defines
/// no names itself.
public struct CommandID: Hashable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible, Sendable {
    /// The name as text, e.g. `cm_Copy`.
    public let rawValue: String

    /// The name itself, as it is written.
    public var description: String { rawValue }

    /// The command of this name.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The command of this name, written as a literal (`"cm_Copy"`).
    public init(stringLiteral value: String) {
        rawValue = value
    }
}

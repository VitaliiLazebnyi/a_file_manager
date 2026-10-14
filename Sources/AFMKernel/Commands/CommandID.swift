import Foundation

/// The name of a command. Plugins register commands under names; menus, keys and other
/// plugins refer to them by name only. The kernel defines no names itself.
public struct CommandID: Hashable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
}

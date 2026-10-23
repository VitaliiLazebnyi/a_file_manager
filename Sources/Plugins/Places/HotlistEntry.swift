import Foundation

/// One line of the directory hotlist (spec 12 › Directory hotlist editor): a place to go to,
/// a submenu of further entries, or a separator line.
public struct HotlistEntry: Codable, Equatable, Sendable {
    /// What an entry is; the raw value is what the settings store.
    public enum Kind: String, Codable, Sendable {
        /// A place to go to (or a command to run).
        case item = "item"
        /// A submenu holding further entries in `children`.
        case submenu = "submenu"
        /// A separator line.
        case separator = "separator"
    }

    /// A separator line, as the editor adds it.
    public static let separator = Self(kind: .separator, title: "-")

    /// Whether the entry is a place, a submenu or a separator.
    public var kind: Kind
    /// As the user typed it; an `&` marks the letter after it (spec 12 › Editing entries).
    public var title: String
    /// What choosing the entry does: `cd <path>` or the name of a command (`HotlistAction`).
    public var command: String
    /// Shown in the other panel at the same time; empty for none.
    public var target: String
    /// The entries of a submenu, in display order; empty for any other kind.
    public var children: [Self]

    /// The title as it is shown: without the `&` that marks an accelerator (`&&` is an ampersand).
    public var displayTitle: String {
        title
            .replacingOccurrences(of: "&&", with: "\u{0}")
            .replacingOccurrences(of: "&", with: "")
            .replacingOccurrences(of: "\u{0}", with: "&")
    }

    /// An entry of `kind`; an item without a command does nothing, a submenu without children is empty.
    public init(kind: Kind, title: String, command: String = "", target: String = "", children: [Self] = []) {
        self.kind = kind
        self.title = title
        self.command = command
        self.target = target
        self.children = children
    }

    /// A place to go to: choosing it runs `command` and shows `target` in the other panel, unless it is empty.
    public static func item(_ title: String, command: String, target: String = "") -> Self {
        Self(kind: .item, title: title, command: command, target: target)
    }

    /// A submenu titled `title` holding `children`.
    public static func submenu(_ title: String, _ children: [Self] = []) -> Self {
        Self(kind: .submenu, title: title, children: children)
    }

    /// An entry for what the user typed as a title: a single `-` makes a separator.
    public static func titled(_ title: String, command: String) -> Self {
        title.trimmingCharacters(in: .whitespaces) == "-" ? .separator : .item(title, command: command)
    }
}

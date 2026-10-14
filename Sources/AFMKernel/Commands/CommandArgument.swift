public import Foundation

/// What a command is given to work on.
///
/// Most commands take nothing and act on the source panel.
public enum CommandArgument: Equatable, Sendable {
    /// A position, such as the number of a tab.
    case index(Int)
    /// A place on a file system: the file to view, the folder to show.
    case location(URL)
    /// Nothing: the command acts on the source panel.
    case nothing
    /// Text such as a new name.
    case text(String)

    /// The place, when the argument is one; nil otherwise.
    public var location: URL? {
        if case .location(let url) = self {
            return url
        }
        return nil
    }

    /// The text, when the argument is one; nil otherwise.
    public var text: String? {
        if case .text(let text) = self {
            return text
        }
        return nil
    }

    /// The position, when the argument is one; nil otherwise.
    public var index: Int? {
        if case .index(let index) = self {
            return index
        }
        return nil
    }
}

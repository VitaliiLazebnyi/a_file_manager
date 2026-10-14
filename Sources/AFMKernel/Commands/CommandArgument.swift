public import Foundation

/// What a command is given to work on. Most commands take nothing and act on the source panel.
public enum CommandArgument: Equatable, Sendable {
    case none
    /// A place on a file system: the file to view, the folder to show.
    case location(URL)
    /// Text such as a new name.
    case text(String)
    /// A position, such as the number of a tab.
    case index(Int)

    public var location: URL? {
        if case .location(let url) = self { return url }
        return nil
    }

    public var text: String? {
        if case .text(let text) = self { return text }
        return nil
    }

    public var index: Int? {
        if case .index(let index) = self { return index }
        return nil
    }
}

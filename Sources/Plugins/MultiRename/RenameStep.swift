import Foundation

/// One rename the file system is asked for.
internal struct RenameStep: Equatable {
    /// What the step does for its item.
    internal enum Kind: Equatable {
        /// Straight to the new name.
        case direct
        /// Out of the way, to a temporary name, because the item's own new name is still taken
        /// by another item of the list.
        case park
        /// From the temporary name to the new one.
        case unpark
    }

    /// The index of the item in the list the plan was made for.
    internal let item: Int
    /// Where the item is before the step.
    internal let from: URL
    /// Where the step puts it.
    internal let destination: URL
    /// What the step does.
    internal let kind: Kind
    /// The new name differs from the old one only in what the file system does not tell
    /// apart (letter case): the rename lands on the file itself.
    internal let ontoItself: Bool
}

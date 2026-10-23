/// How an item of the rename list stands (spec 09 › Start!, collisions, Undo, Result list).
internal enum RenameStatus: Equatable {
    /// Another item of the list ends up with the same name.
    case duplicate
    /// The masks give no name: `<Error!>`.
    case error
    /// A file that is not being renamed away already has the name.
    case exists
    /// The name cannot be given to a file; the text says why.
    case invalid(String)
    /// The item gets its new name when the run starts.
    case ready
    /// The new name is the old one.
    case unchanged

    /// Whether the new name collides with another item or file.
    internal var isConflict: Bool { self == .duplicate || self == .exists }
}

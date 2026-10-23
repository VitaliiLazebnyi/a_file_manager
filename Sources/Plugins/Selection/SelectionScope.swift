import AFMKernel

/// Which entries a selection command affects (spec 03 › Selection, *Selection (with Num +)*).
internal enum SelectionScope {
    /// Files and folders.
    case both
    /// Files only.
    case files
    /// Folders only.
    case folders

    /// Whether the scope lets the entry through.
    internal func contains(_ item: FileItem) -> Bool {
        switch self {
        case .both:
            return true

        case .files:
            return !item.isFolder

        case .folders:
            return item.isFolder
        }
    }
}

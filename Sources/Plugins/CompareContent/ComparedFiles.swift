public import AFMKernel

/// The outcome of loading and comparing two files.
public struct ComparedFiles: Sendable {
    /// Whether the two files have the same bytes.
    public var isIdentical = false
    /// What the window shows; empty when the files are identical without being loaded, or could not be read.
    public var content = CompareContent.empty
    /// Why there is nothing to show: a file is missing, unreadable, or too large.
    public var message: String?
    /// Whether the load was cancelled before it was done; what is here is then incomplete.
    public var wasCancelled = false
    /// The left file as it was when loaded (nil for a link, which is saved where it leads).
    ///
    /// What saving checks the file against, so that a file changed by someone else meanwhile is not overwritten.
    public var leftItem: FileItem?
    /// The right file as it was when loaded; see `leftItem`.
    public var rightItem: FileItem?
}

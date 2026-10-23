/// What a run did.
internal struct RenameRunResult {
    /// The renames carried out, in the order they were done.
    internal var renamed: [RenamedItem] = []
    /// Item index and what went wrong.
    internal var failures: [(item: Int, message: String)] = []
    /// The run was stopped before its end.
    internal var cancelled = false
}

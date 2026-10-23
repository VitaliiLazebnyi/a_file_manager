/// What became of a child process.
internal struct ProcessOutcome {
    /// Standard output and standard error in the order they were written.
    internal var output = ""
    /// The exit status of the child; 0 until it has ended.
    internal var status: Int32 = 0
    /// More was written than is kept.
    internal var isTruncated = false
    /// The child was asked to end before it was done (the job was cancelled).
    internal var wasCancelled = false
    /// Set when the process could not be started at all.
    internal var failure: String?
}

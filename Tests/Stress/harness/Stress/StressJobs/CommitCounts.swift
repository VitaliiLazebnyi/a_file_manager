/// The commits a `DeferredTarget` saw.
internal struct CommitCounts: Sendable {
    /// How many succeeded.
    internal let succeeded: Int
    /// How many failed.
    internal let failed: Int
    /// The last change a successful commit covers.
    internal let covered: Int
}

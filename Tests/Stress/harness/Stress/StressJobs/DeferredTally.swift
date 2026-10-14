/// What one run against the deferring target did to the source files.
internal struct DeferredTally: Sendable {
    /// Source files that were removed.
    internal var removed = 0
    /// Source files that were kept.
    internal var kept = 0
}

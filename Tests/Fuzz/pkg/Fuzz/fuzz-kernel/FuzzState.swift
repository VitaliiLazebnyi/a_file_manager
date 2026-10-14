/// What the targets keep between inputs; they run on the main thread, and so does this.
@MainActor
internal enum FuzzState {
    /// The longest one mask match has taken so far, in seconds.
    internal static var slowestMask = 0.0

    /// With `uniqueNames`, no two items have the same bytes for a name (as in a folder on a disk).
    ///
    /// Names that differ only in their writing (é composed and decomposed) stay.
    internal static var uniqueNames = true

    /// The generator the panel targets shuffle listings with; seeded again for each input.
    internal static var shuffler = Shuffler(state: 42)
}

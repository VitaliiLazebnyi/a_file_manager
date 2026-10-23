/// The change an edit made, for Undo.
extension CompareSession {
    /// One change to the lines of one side: `removed` stood at `start`, and `insertedCount` lines stand there now.
    ///
    /// Undo puts the removed lines back; nothing of the files is copied for it.
    internal struct Splice {
        /// The side whose lines changed.
        internal var side: CompareSide
        /// The index of the first line changed.
        internal var start: Int
        /// The lines that stood there before.
        internal var removed: [TextLine]
        /// How many lines stand there now.
        internal var insertedCount: Int
    }
}

/// What becomes of a prepared change.
extension PanelModel {
    /// What became of a prepared change.
    public enum Outcome: Sendable {
        /// Applied; `onChange` was called.
        case changed
        /// The model has changed since the basis was taken (its list, filter or order): nothing was
        /// done.
        ///
        /// The caller takes a new basis and prepares again, in the background.
        case stale
        /// Applied, and nothing the panel shows is different (a refresh that found the
        /// directory as it was).
        case unchanged
    }
}

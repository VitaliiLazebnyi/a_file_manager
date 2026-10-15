/// How old entries are found in a new list.
extension PanelModel {
    /// How the entries of a list that is replaced are found in the new one.
    internal enum Moves {
        /// By their names, looked up when needed.
        case byName
        /// The new place of every old one; `UInt32.max` for an entry that is gone.
        case table([UInt32])
    }
}

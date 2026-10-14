/// A fresh reading of the directory shown.
extension PanelModel {
    /// A fresh reading of the directory the panel shows, as a prepared change holds it.
    internal struct Reading {
        /// The reading.
        internal let listing: Listing
        /// The item the cursor goes to; nil keeps it on its item.
        internal let focus: String?
        /// Whether the reading holds the entries the panel has.
        internal let isSame: Bool
    }
}

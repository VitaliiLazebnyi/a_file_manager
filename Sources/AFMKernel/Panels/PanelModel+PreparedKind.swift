/// Which change a prepared change is.
extension PanelModel {
    /// Which change a `Prepared` holds.
    internal enum PreparedKind {
        /// A directory that is arriving piece by piece, grown.
        case extend
        /// The list through another filter.
        case filter
        /// A reading of another directory, entered as `show` or `showRemembered` enter it.
        case show(PanelVisit)
        /// Calculated sizes written into copies of the lists, which are otherwise as they were:
        /// good for as long as no other size was set (`sizeStamp`).
        ///
        /// `sized` is the places that have a size now.
        case sizes(sizeStamp: Int, sized: Bitset)
        /// The list in another order.
        case sort
        /// A fresh reading of the directory the panel shows.
        case update(Reading)
    }
}

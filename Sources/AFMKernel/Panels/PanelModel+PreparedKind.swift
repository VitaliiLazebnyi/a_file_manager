/// Which change a prepared change is.
extension PanelModel {
    /// Which change a `Prepared` holds.
    internal enum PreparedKind {
        /// A directory that is arriving piece by piece, grown; how the entries it had are found.
        case extend(Moves)
        /// The list through another filter.
        case filter
        /// A reading of another directory, entered as `show` or `showRemembered` enter it.
        case show(PanelVisit)
        /// Calculated sizes written into copies of the lists, which are otherwise as they were:
        /// good for as long as no other size was set (`sizeStamp`).
        ///
        /// `sized` is the places that have a size now.
        case sizes(sizeStamp: Int, sized: Bitset)
        /// A fresh reading of the directory the panel shows, holding the entries the panel has.
        case sameEntries(Reading)
        /// The list in another order: the new place of every entry.
        case sort([UInt32])
        /// An order the list is in already: only its name changes.
        case sortName
        /// A fresh reading of the directory the panel shows; how the entries it had are found.
        case update(Reading, Moves)
    }
}

/// A list in a panel's order with what its filter shows of it, worked out (on any thread) to take
/// the place of the panel's lists, and how the entries of the lists it replaces are found in it.
///
/// Once it was taken it holds the lists it replaced, which are then released.
internal struct ArrangedLists {
    /// Every entry, in order.
    internal var listed: [FileItem]
    /// The entries the filter shows.
    internal var shown: [FileItem]
    /// Which entries of `listed` are shown; nil when all are.
    internal let places: ShownPlaces?
    /// The index of the names of `listed`, when it was made along with the work.
    internal let index: NameIndex?
    /// The count of `shown`, when it was made along with the work.
    internal let tally: Tally?
    /// Where the entries of the replaced list are in this one.
    internal let moves: PanelModel.Moves

    /// Lets go of whatever lists this holds, in the background.
    internal mutating func discard() {
        Discard.later(&listed)
        Discard.later(&shown)
    }
}

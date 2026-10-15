/// A directory that was read, as `PanelModel.show` and `showRemembered` enter it: where the
/// cursor goes, what the visit does to the history, and whether the list is all there is.
internal struct PanelVisit: Sendable {
    /// The directory with its entries.
    internal let listing: Listing
    /// The item the cursor goes to.
    internal let focus: String?
    /// What the visit does to the history.
    internal let history: PanelModel.HistoryEffect
    /// False while more pieces of the directory follow.
    internal let complete: Bool
    /// True for an earlier reading kept in memory, while a fresh one is under way.
    internal let remembered: Bool
}

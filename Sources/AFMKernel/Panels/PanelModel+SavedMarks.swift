/// What Save Selection keeps.
extension PanelModel {
    /// What Save Selection kept: places of the present list for as long as it is shown, and
    /// names once the panel has left it (the marks are put back by name in another folder).
    internal enum SavedMarks {
        /// The names of the marked entries of a list the panel has left.
        case names(Set<ExactName>)
        /// Nothing was saved, or nothing was marked when it was.
        case nothing
        /// The marked places of the list that is shown.
        case places(Bitset)
        /// A long saved selection of a list the panel has left: the names are in the list.
        case remains(Remains, Bitset)
    }
}

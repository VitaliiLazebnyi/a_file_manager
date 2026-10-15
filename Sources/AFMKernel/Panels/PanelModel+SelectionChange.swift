/// How a set of rows changes the selection.
extension PanelModel {
    /// How a set of rows changes the selection (`setSelection(_:_:)`).
    public enum SelectionChange: Sendable {
        /// The rows are marked besides what is marked.
        case add
        /// The rows lose their marks.
        case remove
        /// The rows become the whole selection.
        case replace
    }
}

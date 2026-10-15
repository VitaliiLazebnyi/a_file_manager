/// What a listing does to the history.
extension PanelModel {
    /// What a new listing does to the visited-directories history.
    public enum HistoryEffect: Sendable {
        /// A reload or correction: nothing changes.
        case keep
        /// A new place: recorded after the current position, dropping what lay ahead.
        case record
        /// Go Back / Go Forward: the position moves by this many places, the list stays.
        case step(Int)
    }
}

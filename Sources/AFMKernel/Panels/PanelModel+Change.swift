/// What `onChange` announces.
extension PanelModel {
    /// What a call of `onChange` announces.
    public enum Change: Sendable {
        /// The directory, its items or their order.
        case contents
        /// The cursor was moved by a command.
        case cursor
        /// The marked items or a calculated folder size.
        case selection
    }
}

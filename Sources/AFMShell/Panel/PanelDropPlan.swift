import AFMContracts
import Foundation

/// What a drop on a panel would do.
internal struct PanelDropPlan {
    /// A copy or a move.
    internal let kind: TransferKind
    /// What is dropped.
    internal let sources: [URL]
    /// The folder it goes into.
    internal let destination: URL
    /// The row to frame while the mouse is over it; -1 is the list as a whole.
    internal let row: Int
}

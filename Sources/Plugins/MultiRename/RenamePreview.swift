import Foundation

/// The new names of a list and how each of them stands.
internal struct RenamePreview {
    /// How the items stand, worked out with the preview (in the background) so that whoever
    /// shows it need not count the rows.
    internal struct Counts: Equatable {
        /// The items that get a new name.
        internal var changing = 0
        /// The items whose new name collides with another item or file.
        internal var conflicts = 0
        /// The items that get no usable name.
        internal var errors = 0
    }

    /// The new name of each item; nil is `<Error!>`.
    internal var names: [String?]
    /// Where each item goes; nil where there is no usable name.
    internal var targets: [URL?]
    /// How each item stands.
    internal var statuses: [RenameStatus]
    /// The planner of the folders the items are in and go to.
    internal var planner: RenamePlanner
    /// The keys of everything that is in the target folders now.
    internal var existing: Set<String>
    /// What is wrong with the settings as a whole (an invalid mask or expression).
    internal var problem: (any Error)?

    /// The items whose new name collides, in list order.
    internal var conflicts: [Int] { statuses.indices.filter { statuses[$0].isConflict } }

    /// How many items change, collide or get no usable name.
    internal var counts: Counts {
        var tally = Counts()
        for status in statuses {
            switch status {
            case .ready:
                tally.changing += 1

            case .duplicate, .exists:
                tally.conflicts += 1

            case .error, .invalid:
                tally.errors += 1

            case .unchanged:
                break
            }
        }
        return tally
    }
}

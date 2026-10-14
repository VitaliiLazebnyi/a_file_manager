/// A change worked out in the background.
extension PanelModel {
    /// A change of the list, worked out by a `prepare` function and waiting for `apply`.
    ///
    /// Whatever it holds is released in the background, taken or not.
    ///
    /// Unchecked: made on one thread and handed to the main thread, which alone changes it
    /// from then on (`apply`).
    public final class Prepared: @unchecked Sendable {
        /// Which change this is.
        internal private(set) var kind: PreparedKind
        /// The basis's `stamp`: the change fits the model only while the model's is the same.
        internal let stamp: Int
        /// The lists that take the place of the model's.
        internal var lists: ArrangedLists
        /// The order the lists are in.
        internal let sort: ListOrder
        /// The filter `lists.shown` went through.
        internal let filter: PanelFilter?

        /// A change of `kind`, worked out from `basis`.
        internal init(
            _ kind: PreparedKind,
            from basis: Basis,
            lists: ArrangedLists,
            sort: ListOrder,
            filter: PanelFilter?
        ) {
            (self.kind, stamp, self.lists, self.sort, self.filter) = (kind, basis.stamp, lists, sort, filter)
        }

        /// The lists are the model's now, or its own again: nothing is left to release.
        internal func forget() {
            (lists.listed, lists.shown) = ([], [])
        }

        deinit {
            lists.discard()
            // The reading itself, which `kind` keeps: when the folder was found as it was,
            // this is the last holder of a list as long as the folder, and it goes where
            // this object goes, which is the main thread right after `apply`.
            var fresh: [FileItem] = []
            switch kind {
            case .update(let reading):
                fresh = reading.listing.items

            case .show(let visit):
                fresh = visit.listing.items

            default:
                break
            }
            kind = .sort
            Discard.later(&fresh)
        }
    }
}

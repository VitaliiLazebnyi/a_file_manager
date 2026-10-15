public import Foundation

/// What background work on the list starts from.
extension PanelModel {
    /// What a change of the list is worked out from: the lists as they are now, with the filter and
    /// the order.
    ///
    /// Taken on the main thread, which costs nothing (the lists are shared, not copied), and handed
    /// to a `prepare` function on any thread.
    ///
    /// Unchecked: the lists are changed only in `deinit`, when nobody else holds the basis.
    public final class Basis: @unchecked Sendable {
        /// The directory the panel showed.
        public let directory: URL
        /// Every entry of the list, in order (`PanelModel.listedItems`).
        public private(set) var listedItems: [FileItem]
        /// The shown entries (`PanelModel.items`).
        public private(set) var items: [FileItem]
        /// The filter the list was shown through.
        public let filter: PanelFilter?
        /// The order the list was in.
        public let sort: ListOrder
        /// `PanelModel.requestedSort` when the basis was taken.
        public let requestedSort: ListOrder?
        /// The model's `stamp` when the basis was taken.
        internal let stamp: Int
        /// The model's `sizeStamp` when the basis was taken.
        internal let sizeStamp: Int
        /// Which entries were shown; nil when all were.
        internal let places: ShownPlaces?
        /// The index of the names, if the model had made one.
        internal let index: NameIndex?
        /// The places with a calculated size, if the model knew them; as long as the list.
        internal let sized: Bitset?
        /// Whether the lists are released in the background when the basis goes.
        private let discards: Bool

        /// The order a list that arrives is put into: the requested one, else the present one.
        internal var wantedSort: ListOrder { requestedSort ?? sort }

        /// The model as it is now.
        ///
        /// With `discards`, the basis may outlive the model's lists and lets go of them in the
        /// background.
        @MainActor
        internal init(_ model: PanelModel, discards: Bool) {
            (directory, listedItems, items) = (model.directory, model.listedItems, model.items)
            (filter, sort, stamp, places) = (model.filter, model.sort, model.stamp, model.shownPlaces)
            (sizeStamp, requestedSort, index) = (model.sizeStamp, model.requestedSort, model.lookups.index)
            sized = model.sized
            self.discards = discards
        }

        deinit {
            // The model may have moved on; then this is the last holder of a long list.
            if discards {
                Discard.later(&listedItems)
                Discard.later(&items)
            }
        }
    }

    /// The model as it is now, for a `prepare` function.
    public var basis: Basis { Basis(self, discards: true) }
}

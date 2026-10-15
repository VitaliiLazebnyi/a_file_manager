/// Lists that are no longer shown, kept by whoever may still want them (a snapshot, a list that was
/// worked out and not taken).
///
/// When the last holder lets go, on whatever thread, the memory is released in the background.
///
/// Unchecked: `lists` is changed only in `deinit`, when nobody else holds the object.
internal final class Remains: @unchecked Sendable {
    /// The lists, in the order they were handed in.
    internal private(set) var lists: [[FileItem]]

    /// Keeps the lists.
    internal init(_ lists: [FileItem]...) {
        self.lists = lists
    }

    deinit {
        for index in lists.indices { Discard.later(&lists[index]) }
    }
}

/// Looks names up in one list, with an index once it has been asked a few times (see
/// `NameLookups`).
///
/// For one thread.
internal final class NameFinder {
    /// The list the names are looked up in.
    internal let items: [FileItem]
    private var lookups: NameLookups

    /// The index of the list's names, once it was made or handed in.
    internal var index: NameIndex? { lookups.index }

    /// A finder for `items`, starting with their index if one was made of them already.
    internal init(_ items: [FileItem], index: NameIndex?) {
        (self.items, lookups) = (items, NameLookups(index: index))
    }

    /// A finder for `items` that makes the index when it is asked often enough.
    internal convenience init(_ items: [FileItem]) {
        self.init(items, index: nil)
    }

    /// Makes the index now: lookups from several threads may follow.
    internal func prepare() -> NameIndex {
        if let made = lookups.index {
            return made
        }
        let made = NameIndex(items)
        lookups.index = made
        return made
    }

    /// Every place of the name as it is written.
    internal func places(of name: String) -> [Int] {
        lookups.places(ofExactly: name, in: items)
    }

    /// The place of an entry that was at `hint` or near it in another list: the entry of the
    /// same name there, else wherever the name is; of several entries with the name, the one
    /// at the same location.
    internal func place(of item: FileItem, near hint: Int) -> Int? {
        ListWork.place(of: item, near: hint, in: items) { places(of: $0) }
    }

    deinit {
        // Nothing to release.
    }
}

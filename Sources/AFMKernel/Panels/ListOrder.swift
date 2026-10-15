/// The order of a panel's list: a key and a direction.
public struct ListOrder: Equatable, Sendable {
    /// What the files are sorted by.
    public var key: SortKey
    /// Whether the files' order is turned round; folders always go by name, ascending.
    public var descending: Bool

    /// An order; by name, ascending, unless said otherwise.
    public init(key: SortKey = .name, descending: Bool = false) {
        self.key = key
        self.descending = descending
    }
}

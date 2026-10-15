public import Foundation

/// What is remembered of one folder tab between sessions (`PanelTabs.State`).
public struct PanelTabState: Codable, Equatable, Sendable {
    /// The names the fields are stored by.
    private enum CodingKeys: String, CodingKey {
        case descending = "descending"
        case location = "location"
        case locked = "locked"
        case showHidden = "showHidden"
        case sortKey = "sortKey"
        case title = "title"
    }

    /// The location as a URL string, so it can be on any file system.
    public var location: String
    /// The raw value of the tab's `SortKey`.
    public var sortKey: Int
    /// Whether the tab's order is reversed.
    public var descending: Bool
    /// Whether the tab lists hidden files.
    public var showHidden: Bool
    /// The name the user gave the tab; nil shows the folder's name.
    public var title: String?
    /// Whether the tab is locked against closing.
    public var locked: Bool

    /// The state of a tab at `location`.
    public init(
        location: URL,
        order: ListOrder = ListOrder(),
        showHidden: Bool = false,
        title: String? = nil,
        locked: Bool = false
    ) {
        self.location = location.absoluteString
        (sortKey, descending) = (order.key.rawValue, order.descending)
        (self.showHidden, self.title, self.locked) = (showHidden, title, locked)
    }

    /// Reads a stored tab; a tab stored without `locked` is not locked.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        location = try container.decode(String.self, forKey: .location)
        sortKey = try container.decode(Int.self, forKey: .sortKey)
        descending = try container.decode(Bool.self, forKey: .descending)
        showHidden = try container.decode(Bool.self, forKey: .showHidden)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        locked = try container.decodeIfPresent(Bool.self, forKey: .locked) ?? false
    }

    /// Stores the tab; `locked` only for a locked tab, as it always was.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(location, forKey: .location)
        try container.encode(sortKey, forKey: .sortKey)
        try container.encode(descending, forKey: .descending)
        try container.encode(showHidden, forKey: .showHidden)
        try container.encodeIfPresent(title, forKey: .title)
        if locked { try container.encode(true, forKey: .locked) }
    }
}

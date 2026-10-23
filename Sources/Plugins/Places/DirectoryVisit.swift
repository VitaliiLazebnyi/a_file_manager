import AFMKernel
import Foundation

/// One directory in a panel's `DirectoryHistory`.
public struct DirectoryVisit: Codable, Equatable {
    /// The stored field names; `key` is worked out again on reading, so it is not among them.
    private enum CodingKeys: String, CodingKey {
        case location = "location"
        case isVisible = "isVisible"
    }

    /// The location as a URL string, so it can be on any file system.
    public var location: String
    /// False for a folder that was only passed through: thinning hides it from the list.
    public var isVisible: Bool
    /// The location key of `location`, worked out once, so that looking a visit up does not
    /// parse a URL for each of the 200 that are kept.
    ///
    /// Not stored.
    public private(set) var key: String

    /// A visit of `location` (a URL string); its key is empty when `location` is no URL.
    public init(location: String, isVisible: Bool) {
        self.location = location
        self.isVisible = isVisible
        key = URL(string: location)?.locationKey ?? ""
    }

    /// Reads a stored visit leniently (see `StoredSettings`): a missing `isVisible` counts as false.
    ///
    /// Throws when the location is missing or not a string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            location: try container.decode(String.self, forKey: .location),
            isVisible: try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? false
        )
    }
}

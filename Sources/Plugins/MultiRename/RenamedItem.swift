import Foundation

/// A rename that was carried out, for Undo and the result log.
///
/// Stored with the keys `from` and `to` in the undo history of the settings.
internal struct RenamedItem: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case destination = "to"
        case from = "from"
    }

    /// Where the item was.
    internal var from: URL
    /// Where it is now.
    internal var destination: URL
}

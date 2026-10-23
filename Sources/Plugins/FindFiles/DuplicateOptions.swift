/// "Find duplicate files" of the Advanced tab (spec 09 › Duplicate finder).
///
/// The ticked sub-criteria must all hold between the files of a group.
public struct DuplicateOptions: Codable, Equatable, Sendable {
    /// Whether the box "Find duplicate files" is ticked.
    public var isEnabled: Bool
    /// The files of a group have the same name (case ignored).
    public var sameName: Bool
    /// The files of a group have the same size.
    public var sameSize: Bool
    /// The files of a group have the same contents, byte for byte (compared by their SHA-256).
    public var sameContents: Bool

    /// Whether the option takes part in a search.
    ///
    /// With no sub-criterion ticked the option counts as off.
    public var isActive: Bool { isEnabled && (sameName || sameSize || sameContents) }

    /// The option with the given boxes ticked; by default off, and when switched on, by name and size.
    public init(isEnabled: Bool = false, sameName: Bool = true, sameSize: Bool = true, sameContents: Bool = false) {
        self.isEnabled = isEnabled
        self.sameName = sameName
        self.sameSize = sameSize
        self.sameContents = sameContents
    }
}

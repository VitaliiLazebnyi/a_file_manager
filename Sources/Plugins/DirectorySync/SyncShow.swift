/// The Show buttons (spec 09 › Show filter); the raw values are the `SyncButtons` bits.
public struct SyncShow: OptionSet, Codable, Equatable, Sendable {
    /// Rows the comparison copies to the right.
    public static let copyToRight = Self(rawValue: 1)
    /// Rows that are equal.
    public static let equal = Self(rawValue: 2)
    /// Rows that differ and are copied in neither direction.
    public static let notEqual = Self(rawValue: 4)
    /// Rows the comparison copies (or deletes) to the left.
    public static let copyToLeft = Self(rawValue: 8)
    /// Rows on both sides.
    public static let duplicates = Self(rawValue: 16)
    /// Rows on one side only.
    public static let singles = Self(rawValue: 32)
    /// Every button down.
    public static let all = Self(rawValue: 63)

    /// The bits of the buttons that are down.
    public let rawValue: Int

    /// The buttons of these bits.
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Rows are filtered by the direction the comparison computed, not by what the user made
    /// of it, and by whether the file is on both sides or on one.
    public func shows(_ row: SyncRow) -> Bool {
        let direction: Self
        switch row.defaultAction {
        case .copyToRight:
            direction = .copyToRight

        case .copyToLeft, .deleteRight:
            direction = .copyToLeft

        default:
            direction = row.state == .equal ? .equal : .notEqual
        }
        return contains(direction) && contains(row.isPair ? .duplicates : .singles)
    }
}

/// A state of the Advanced tab's attribute boxes: must be set, must not be set, or either.
///
/// Stored by its number in saved searches.
public enum TriState: Int, Codable, Sendable {
    /// Either: the attribute is not looked at (the box is mixed).
    case any = 0
    /// The attribute must be set (the box is ticked).
    case set = 1
    /// The attribute must not be set (the box is clear).
    case unset = 2

    /// Whether a file whose attribute is `value` passes.
    internal func accepts(_ value: Bool) -> Bool {
        self == .any || (self == .set) == value
    }
}

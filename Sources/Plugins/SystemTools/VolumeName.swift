/// The rules for a volume's name (spec 12 › Volume label, adapted: the Mac allows long names
/// and most characters, but neither `/` nor `:` nor a leading dot).
internal enum VolumeName {
    /// The longest name a volume may have, in bytes of UTF-8.
    internal static let maximumLength = 255

    /// Nil when the name is fine, else what is wrong with it.
    internal static func problem(with name: String) -> String? {
        if name.isEmpty {
            return "The name must not be empty."
        }
        if name.utf8.count > maximumLength {
            return "The name is too long."
        }
        if name.contains("/") || name.contains(":") {
            return "The name must not contain / or :."
        }
        if name.hasPrefix(".") {
            return "The name must not start with a dot."
        }
        return nil
    }
}

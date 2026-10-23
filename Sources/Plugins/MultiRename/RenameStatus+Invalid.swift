/// Whether a status is that of a name that cannot be used.
extension RenameStatus {
    /// The new name is not one a file can have (`.invalid`, whatever the reason).
    internal var isInvalid: Bool {
        if case .invalid = self {
            return true
        }
        return false
    }
}

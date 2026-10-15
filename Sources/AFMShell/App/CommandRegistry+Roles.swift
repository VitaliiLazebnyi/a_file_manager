import AFMKernel

/// The commands that stand in for the standard editing actions.
extension CommandRegistry {
    /// The command a plugin registered for an editing role (Cut, Copy, Paste, Select All);
    /// nil when no plugin did.
    internal func command(with role: EditingRole) -> CommandID? {
        all.first { $0.editingRole == role }?.id
    }
}

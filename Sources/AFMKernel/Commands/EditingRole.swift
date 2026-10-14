import Foundation

/// The standard editing action a command shares its key with.
///
/// The shell sends such a command along the system's editing path, so text fields keep Cmd+C, Cmd+V, Cmd+X and Cmd+A.
public enum EditingRole: Sendable {
    /// Copy, Cmd+C.
    case copy
    /// Cut, Cmd+X.
    case cut
    /// Paste, Cmd+V.
    case paste
    /// Select All, Cmd+A.
    case selectAll
}

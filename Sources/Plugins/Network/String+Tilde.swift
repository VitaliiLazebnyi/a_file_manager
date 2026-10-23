import Foundation

/// Paths the user types, where `~` stands for a home folder.
extension String {
    /// This path with a leading `~` or `~user` replaced by that user's home folder.
    ///
    /// The same as `NSString.expandingTildeInPath` for a path that starts with one: `~` and `~/Music` go to the
    /// current user's home folder, `~guest/Music` to the home folder of `guest`. A path without a leading `~`, or one
    /// that names a user the system does not know, comes back unchanged.
    internal var expandingTilde: String {
        guard hasPrefix("~") else {
            return self
        }
        let user = String(dropFirst().prefix { $0 != "/" })
        guard let home = user.isEmpty ? NSHomeDirectory() : NSHomeDirectoryForUser(user) else {
            return self
        }
        return home + dropFirst(1 + user.count)
    }
}

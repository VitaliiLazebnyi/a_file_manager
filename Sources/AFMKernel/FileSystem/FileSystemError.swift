public import Foundation

/// What a file system throws when an operation cannot be done there at all, as opposed to
/// failing on the disk (which throws the system's own error).
public enum FileSystemError: LocalizedError, Sendable {
    /// The name is taken; nothing existing is overwritten. Holds the location as written for
    /// the user.
    case alreadyExists(String)
    /// A move or copy cannot be done inside the file system; the caller streams the contents.
    case crossesVolumes
    /// No plugin offers a file system for the scheme of this location.
    case noProvider(URL)
    /// The file system cannot do this at all; holds what was asked for ("Moving to the Trash").
    case notSupported(String)

    /// The message the user is shown.
    public var errorDescription: String? {
        switch self {
        case .alreadyExists(let path):
            return "\(path) already exists."

        case .crossesVolumes:
            return "The file cannot be moved or copied inside its file system."

        case .noProvider(let url):
            return "No file system is available for \(url.absoluteString)."

        case .notSupported(let what):
            return "\(what) is not supported here."
        }
    }
}

/// What the caller knows of an entry it asks a session to remove (`RemoteSession.remove`).
internal enum RemovedKind {
    /// A directory, removed with the protocol's command for directories.
    case directory
    /// A file or a link, removed as a file whatever a link points to.
    case file
    /// Not known: the session finds out, or tries one command and then the other.
    case unknown
}

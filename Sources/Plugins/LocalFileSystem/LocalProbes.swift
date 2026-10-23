import Foundation

/// Stand-ins for what the system says about a volume, so that tests can put a volume that
/// has stopped answering, or a disk of a known size, in the place of a real one.
///
/// Set before the file system is used, never afterwards; nil everywhere in the program itself.
internal struct LocalProbes {
    /// Called with a path just before the system is asked about it in a way that can wait on
    /// the volume: a test blocks here for the paths of its "dead" volume.
    internal var willAsk: (@Sendable (String) -> Void)?
    /// Whether a path is on a disk of this Mac; nil asks the mount table.
    internal var isLocal: (@Sendable (String) -> Bool)?
    /// The free space of the volume at a path, plainly free and free for important uses;
    /// nil asks the system.
    internal var freeSpace: (@Sendable (String) -> (available: Int64?, important: Int64?))?
    /// How long a change on a volume that is not a disk of this Mac is waited for after it
    /// was cancelled, in seconds, before the caller goes on without it.
    internal var patienceAfterCancel: TimeInterval = 2
    /// How long a question about a volume (its name, its free space) is waited for before it
    /// is answered from what was last known.
    internal var volumePatience: TimeInterval = 3
    /// How long a reading of the places may take before it is given up, in seconds.
    internal var placesPatience: TimeInterval = 8
    /// Called with every step the system reports while it copies a file (what it copies, and
    /// the stage); true stops the copy there, as the caller's flag would.
    ///
    /// A test cannot choose the moment at which a flag it sets is seen.
    internal var copyStops: (@Sendable (_ what: Int32, _ stage: Int32) -> Bool)?
    /// The home folder whose places are listed; nil is the user's.
    internal var home: URL?
    /// Failures of the system that no test can bring about on a healthy disk of this Mac (a share
    /// that reports a write error only when the file is closed, a volume without bulk reads): for
    /// the name of a system call and the path it is about, the error number it fails with instead
    /// of being made; nil makes the call.
    internal var fault: (@Sendable (_ call: String, _ path: String) -> Int32?)?

    /// Makes the system call `call`, unless `fault` has it fail: the result is then -1, with
    /// `errno` set.
    internal func system<Result: SignedInteger>(_ name: String, _ path: String, _ call: () -> Result) -> Result {
        if let code = fault?(name, path) {
            errno = code
            return -1
        }
        return call()
    }
}

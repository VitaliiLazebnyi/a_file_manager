import Foundation

/// What the viewer reports about the file it is reading.
internal enum ViewerError: LocalizedError, Equatable {
    /// Too many reads that cannot be ended are still waiting on the file systems: nothing more is started.
    case busy
    /// A source of unknown size that does not end (a device behind a link, a stream).
    case endless(String)
    /// A read inside the length the file had when it was opened came back short: the file was
    /// truncated or replaced while it was shown, and what is shown is incomplete.
    case fileChanged
    /// A pipe, a device or a socket: reading it may never end.
    case notAFile(String)

    /// The sentence the viewer shows for the error, with the file's name where it has one.
    internal var errorDescription: String? {
        switch self {
        case .fileChanged:
            return "The file changed while it was being read (it became shorter); what is shown may be incomplete."

        case .notAFile(let name):
            return "\(name) is not a regular file (a pipe, device or socket), and cannot be shown."

        case .endless(let name):
            return "\(name) does not end, and cannot be shown."

        case .busy:
            return "Too many reads are still waiting for a volume that does not answer; this file was not read."
        }
    }
}

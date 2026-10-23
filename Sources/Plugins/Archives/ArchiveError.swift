import Foundation

/// What can go wrong with an archive; each case carries the name or text the message shows.
internal enum ArchiveError: LocalizedError {
    /// The user stopped the operation.
    case cancelled
    /// The archive file was changed by another program since it was read; the changes made here were dropped.
    case changedOutside(String)
    /// A member's data does not match its checksum.
    case crcMismatch(String)
    /// The archive's structure is broken; the text says where.
    case damaged(String)
    /// Several files would be stored under one name.
    case nameCollision(String)
    /// The archive's volume has no room for the changed archive.
    case noRoom(String)
    /// The temporary folder's volume has no room to spare for a copy of the archive.
    case noScratchRoom(String)
    /// A path that should be a folder in the archive is a file.
    case notADirectory(String)
    /// The file is no archive of a format the plugin reads.
    case notAnArchive(String)
    /// A path does not exist in the archive.
    case notFound(String)
    /// A member is encrypted and no password was given.
    case passwordNeeded(String)
    /// The archive's format cannot be changed in place.
    case readOnly(String)
    /// The store has let this archive go; whoever wanted to change it asks the store again.
    /// Never reaches the user.
    case retired
    /// A tool of the system failed; the text is its message.
    case toolFailed(String)
    /// Changes that could not be written before the program quit; the text says what became of them.
    case unsaved(String)
    /// Something the archive uses (a method, an encryption, a kind of member) is not supported.
    case unsupported(String)
    /// The password does not open the member.
    case wrongPassword(String)

    /// The message shown to the user.
    internal var errorDescription: String? {
        switch self {
        case .notAnArchive(let name):
            return "\(name) is not an archive, or its format is not supported."

        case .damaged(let what):
            return "The archive is damaged: \(what)."

        case .unsupported(let what):
            return "\(what) is not supported."

        case .wrongPassword(let name):
            return "Wrong password for \(name)."

        case .passwordNeeded(let name):
            return "\(name) is encrypted and no password was given."

        case .crcMismatch(let name):
            return "CRC error in \(name): the data is damaged."

        case .notFound(let path):
            return "\(path) does not exist in the archive."

        case .notADirectory(let path):
            return "\(path) is not a folder."

        case .readOnly(let name):
            return "Archives of this type cannot be changed (\(name))."

        case .changedOutside(let name):
            return "\(name) was changed by another program; the changes made here were not written."

        case .noRoom(let name):
            return "There is not enough room on the disk to write the changes into \(name)."

        case .noScratchRoom(let name):
            return "There is not enough room on the startup disk to open \(name): it has to be copied there first."

        case .nameCollision(let name):
            return
                "Several files would be stored under the name \(name). Pack with path names, or pack them one by one."

        case .unsaved(let what):
            return what

        case .toolFailed(let message):
            return message

        case .cancelled:
            return "The operation was cancelled."

        case .retired:
            return "The archive was read again; please repeat the operation."
        }
    }

    /// Whether the file itself is to blame for `error` (no archive, damaged, unsupported): such a failure
    /// is remembered for a while instead of being met again by every look at the file.
    internal static func isAboutTheFile(_ error: any Error) -> Bool {
        switch error {
        case Self.notAnArchive, Self.damaged, Self.unsupported:
            return true

        default:
            return false
        }
    }
}

import Foundation

/// What is worked out from the files of a list.
extension VirtualFileSystem {
    /// What was worked out from all the files of a `FileList`.
    internal struct PreparedList {
        /// The files, each once.
        internal let entries: [URL]
        /// One entry of each file system the entries are on, which is what can differ.
        internal let examples: [URL]
        /// The folders the files are in, as many as are watched.
        internal let parents: [URL]
        /// Every file is on this computer.
        internal let isLocal: Bool
    }
}

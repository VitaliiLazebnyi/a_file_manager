/// What `flushAll` and `rescueAll` report about each archive.
extension ArchiveStore {
    /// An archive whose changes could not be written (`flushAll`).
    internal struct WriteFailure {
        /// The archive's name, for the message.
        internal let name: String
        /// Why the write failed.
        internal let error: any Error
        /// The archive, whose changes still wait.
        internal let archive: OpenArchive
    }

    /// What became of the waiting changes of an archive (`rescueAll`).
    internal struct Rescue {
        /// The archive's name, for the message.
        internal let name: String
        /// Where the changes went, if anywhere.
        internal let outcome: RescueOutcome
        /// The archive the changes belonged to.
        internal let archive: OpenArchive
    }
}

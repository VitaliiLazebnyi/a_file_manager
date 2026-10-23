internal import Foundation

/// What a connection gets from the session that owns it.
extension FTPConnection {
    /// What the connections of one session share, and how they report: the memories of links and names,
    /// the callbacks for signs of life and for the log, and the clock.
    ///
    /// A connection of its own (a test, a one-off) takes the defaults: fresh memories, no callbacks, the
    /// system clock.
    internal struct Parts {
        /// Where links were found to lead (see `LinkMemory`).
        internal var knownLinks = LinkMemory()
        /// The names that are written back as they came (see `NameMemory`).
        internal var knownNames = NameMemory()
        /// Called whenever the server showed a sign of life (see `FTPConnection.onActivity`).
        internal var onActivity: (@Sendable () -> Void)?
        /// Called with every line sent and received, for the log.
        internal var log: (@Sendable (String) -> Void)?
        /// The time now.
        internal var clock: @Sendable () -> Date = { Date() }
    }
}

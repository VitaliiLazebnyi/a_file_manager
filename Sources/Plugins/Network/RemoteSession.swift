import AFMKernel

/// A live connection to one server, whatever protocol it speaks.
///
/// The file-system provider translates between URLs and the paths these methods take.
///
/// **Threading.** Every method may be called from several threads at once and blocks until
/// the server has answered.
internal protocol RemoteSession: AnyObject, Sendable {
    /// How the session reaches and logs in to its server.
    var profile: ConnectionProfile { get }
    /// True once a login has succeeded.
    var isConnected: Bool { get }
    /// True while a login is under way (also while it waits for the user's answer).
    var isConnecting: Bool { get }
    /// False when asking about one entry costs much more than listing its directory, which the
    /// file system then does once and remembers.
    var singleLookupsAreCheap: Bool { get }
    /// Connects if necessary and returns the directory the login leads to.
    func connect(cancellation: CancellationFlag?) throws -> String
    /// Lists a directory, handing the entries to `receive` in batches until it returns false.
    ///
    /// A set `cancellation` ends the call soon, by throwing `NetworkError.cancelled`, and leaves
    /// the connection in a state it can be used from again, or gone. The same goes for the calls below.
    func list(_ path: String, showHidden: Bool, cancellation: CancellationFlag?, receive: ([RemoteEntry]) -> Bool)
        throws
    /// The entry at a path; nil when nothing is there.
    func entry(at path: String, cancellation: CancellationFlag?) throws -> RemoteEntry?
    /// Opens a file for reading.
    ///
    /// The flag of the three calls that open a file covers the opening only; the reader or writer
    /// is ended with its own `interrupt`.
    func openRead(_ path: String, cancellation: CancellationFlag?) throws -> any FileReader
    /// Starts writing a file that does not exist yet.
    func openWrite(_ path: String, cancellation: CancellationFlag?) throws -> any FileWriter
    /// Whether a file of this name can be continued with `openAppend`.
    ///
    /// Answers at once, from what is known; a server that is not known yet is believed to.
    func canAppend(_ path: String) -> Bool
    /// Continues an existing file: cut to `offset` bytes when given (throws when it is shorter),
    /// else at its end.
    ///
    /// `size` is the length the file has when the writer starts.
    func openAppend(_ path: String, at offset: Int64?, cancellation: CancellationFlag?) throws -> (
        writer: any FileWriter, size: Int64
    )
    /// `handler` is called, from any thread, when the session finds out after a listing where a
    /// link of it leads: the path of the link, and whether it leads to a folder.
    ///
    /// A session that tells at once ignores it.
    func onLinkResolved(_ handler: @escaping @Sendable (_ path: String, _ isDirectory: Bool) -> Void)
    /// Makes a directory.
    ///
    /// The four calls that change something take the caller's flag as well: the wait for a
    /// connection, for another thread's login and for the server's reply ends when it is set
    /// (Cancel in the progress window), with `NetworkError.cancelled`. A command that was
    /// already sent may have been carried out all the same.
    func makeDirectory(_ path: String, cancellation: CancellationFlag?) throws
    /// Removes a file, a link or an empty directory; `kind` is what the caller knows of it.
    func remove(_ path: String, kind: RemovedKind, cancellation: CancellationFlag?) throws
    /// Renames.
    ///
    /// `replacing` asks for an existing file at the destination to be replaced in the
    /// same step where the protocol can say so (SFTP); whether a plain rename replaces depends
    /// on the server. A server that refuses throws what it said (`NetworkError.refused`,
    /// `SFTPError`); nothing is removed to make room.
    func rename(_ source: String, to destination: String, replacing: Bool, cancellation: CancellationFlag?) throws
    /// Sets the dates or permissions `attributes` gives; what it leaves nil stays as it is.
    func setAttributes(_ attributes: FileAttributes, of path: String, cancellation: CancellationFlag?) throws
    /// Closes every connection, also those in use.
    func disconnect()
}

/// What a session has unless it says otherwise, and the calls without a flag for those who cannot cancel.
extension RemoteSession {
    /// Asking about one entry costs about as much as listing, unless the session says otherwise.
    internal var singleLookupsAreCheap: Bool { true }

    /// A session that does not tell is never seen logging in.
    internal var isConnecting: Bool { false }

    /// Removes an entry with nobody to cancel it.
    internal func remove(_ path: String, kind: RemovedKind) throws {
        try remove(path, kind: kind, cancellation: nil)
    }

    /// Renames with nobody to cancel it.
    internal func rename(_ source: String, to destination: String, replacing: Bool) throws {
        try rename(source, to: destination, replacing: replacing, cancellation: nil)
    }

    /// A session whose listings tell where links lead never calls the handler.
    internal func onLinkResolved(_: @Sendable (_ path: String, _ isDirectory: Bool) -> Void) {
        // The listing already said where every link leads.
    }

    /// The entry at a path, with nobody to cancel the question; nil when nothing is there.
    internal func entry(at path: String) throws -> RemoteEntry? { try entry(at: path, cancellation: nil) }

    /// Starts writing a new file, with nobody to cancel the opening.
    internal func openWrite(_ path: String) throws -> any FileWriter { try openWrite(path, cancellation: nil) }
}

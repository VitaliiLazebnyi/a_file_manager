public import AFMKernel
public import Foundation

/// Servers as a file system (spec 11 › The connected panel): `ftp:`, `ftps:` and `sftp:` URLs
/// of the form `scheme://host[:port]/path`.
///
/// A URL never carries a user name or password; those belong to the connection
/// (`ConnectionCenter`). One instance serves one scheme.
///
/// **Threading.** Every method is safe to call from several threads at once: the sessions take
/// care of their connections, and the little state kept here is guarded by locks. The calls
/// that must answer at once (`parent(of:)`, `displayPath(_:)`, `places()`) work on text and
/// on what the center already knows.
public final class RemoteFileSystem: FileSystemProvider {
    /// A location taken apart: the session of its server, the server and the path on it.
    internal struct Resolved {
        /// The session of the server, made when there was none.
        internal let session: any RemoteSession
        /// The server.
        internal let key: ServerKey
        /// The path on the server, normalized.
        internal let path: String
    }

    /// `ftp`, `ftps` or `sftp`: the scheme of the locations this instance serves.
    public let scheme: String
    /// Writing and appending; a server where appending fails says so in `capabilities(for:)`.
    public let capabilities: FileSystemCapabilities = [.write, .append]
    /// The sessions, by server.
    internal let center: ConnectionCenter
    /// The listings read a moment ago, for the questions about single entries.
    internal let cache: EntryCache

    /// Showing a location of this file system may log in to a server.
    public var connectsToServer: Bool { true }

    /// The file system of the `scheme` locations, whose sessions `center` keeps.
    public init(scheme: String, center: ConnectionCenter) {
        self.scheme = scheme
        self.center = center
        cache = EntryCache { Date() }
    }

    /// A file system whose remembered listings age by `clock`.
    internal init(scheme: String, center: ConnectionCenter, clock: @escaping @Sendable () -> Date) {
        self.scheme = scheme
        self.center = center
        cache = EntryCache(now: clock)
    }

    /// True for an answer of the server that says no to a request, as opposed to a connection
    /// that broke or a wait that was ended: only the former says anything about the files.
    internal static func isRefusal(_ error: any Error) -> Bool {
        if error is SFTPError {
            return true
        }
        if case NetworkError.refused(let reply) = error {
            return reply.code != 421
        }
        return false
    }

    /// A name next to `name` for the file that is being replaced, one that nothing else has.
    internal static func asideName(for name: String) -> String {
        let mark = String(UInt32.random(in: 0...UInt32.max), radix: 16)
        // Short enough for servers with a limit of 255 bytes for a name: the characters within the
        // first 180 bytes, without replacement characters.
        var length = 0
        let fitting = name.unicodeScalars.prefix { scalar in
            length += UTF8.width(scalar)
            return length <= 180
        }
        let kept = String(String.UnicodeScalarView(fitting.filter { $0 != "\u{FFFD}" }))
        return ".\(kept).replaced-\(mark)"
    }

    /// `flags;time;agent;event`: downloaded (`0083`, what browsers write), the time in
    /// hexadecimal seconds, the program that fetched it, and no event of the download database.
    internal static func quarantineMark(agent: String, at date: Date) -> Data {
        let name = agent.replacingOccurrences(of: ";", with: " ")
        return Data("0083;\(String(Int(max(0, date.timeIntervalSince1970)), radix: 16));\(name);".utf8)
    }

    /// Takes a location apart and finds the session of its server.
    ///
    /// Throws `NetworkError.cancelled` once `cancellation` is set, `FileSystemError.noProvider` for a location of
    /// another scheme, and `FileSystemError.notSupported` for a path with a name that would melt into a slash.
    internal func resolve(_ url: URL, cancellation: CancellationFlag?) throws -> Resolved {
        if cancellation?.isCancelled == true { throw NetworkError.cancelled }
        guard let key = ServerKey(url), key.scheme == scheme else { throw FileSystemError.noProvider(url) }
        // Every name of the path must read as a name of its own (see `RemotePath.normalized`).
        guard RemotePath.hasSeparableNames(url.path) else {
            throw FileSystemError.notSupported("A name that begins or ends with a combining character")
        }
        return Resolved(session: try center.session(for: key), key: key, path: RemotePath.of(url))
    }

    /// The folder that holds `url`; the root for the root itself.
    internal func parentURL(_ url: URL) -> URL {
        parent(of: url) ?? url
    }

    // MARK: Reading

    /// The entries of a folder on the server, all at once.
    public func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        var items: [FileItem] = []
        try list(directory, showHidden: showHidden) { batch in
            items += batch
            return true
        }
        return items
    }

    /// The entries of a folder in batches as the server sends them; `receive` returns false to stop.
    public func list(_ directory: URL, showHidden: Bool, receive: ([FileItem]) -> Bool) throws {
        try read(directory, showHidden: showHidden, isVisit: true, cancellation: nil, receive: receive)
    }

    /// The entries of a folder, all at once; setting `cancellation` ends the listing.
    public func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
        var items: [FileItem] = []
        try list(directory, showHidden: showHidden, cancellation: cancellation) { batch in
            items += batch
            return true
        }
        return items
    }

    /// The entries of a folder in batches; `receive` returns false to stop, and setting `cancellation` ends it.
    public func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag, receive: ([FileItem]) -> Bool)
        throws
    {
        try read(directory, showHidden: showHidden, isVisit: true, cancellation: cancellation, receive: receive)
    }

    /// Reads a directory and remembers the listing.
    ///
    /// A visit is what the panels do; reading the directory to answer a question about one entry is
    /// not. A cancelled listing is not remembered.
    private func read(
        _ directory: URL,
        showHidden: Bool,
        isVisit: Bool,
        cancellation: CancellationFlag?,
        receive: ([FileItem]) -> Bool
    ) throws {
        let target = try resolve(directory, cancellation: nil)
        let (session, key, path) = (target.session, target.key, target.path)
        let base = key.url(path: path)
        var all: [RemoteEntry] = []
        var complete = true
        let started = cache.now()
        // A link the session resolves after the listing was delivered is a folder in what is remembered, too.
        session.onLinkResolved { [weak self] link, isDirectory in
            guard let self, let parent = RemotePath.parent(of: link) else {
                return
            }
            cache.updateIfKnown(RemotePath.name(of: link), in: key.url(path: parent)) { entry in
                entry.isDirectory = isDirectory
            }
        }
        try session.list(path, showHidden: showHidden, cancellation: cancellation) { entries in
            all += entries
            let visible = showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
            if !visible.isEmpty, !receive(visible.map { $0.item(in: base) }) { complete = false }
            if cancellation?.isCancelled == true { complete = false }
            return complete
        }
        guard complete, cancellation?.isCancelled != true else {
            return
        }
        cache.store(all, for: base, includesHidden: showHidden, startedAt: started)
        if isVisit { center.noteVisited(path, on: key) }
    }

    /// The entry at a location; nil when nothing is there.
    ///
    /// `beforeOverwriting` is for the question "is this name free?" asked before a step that
    /// would silently replace what is there (an upload, a rename). A listing that is a few
    /// seconds old is then not believed when it says "nothing there": the server is asked,
    /// where one question is cheap, and in any case when the listing holds a name that differs
    /// only in case or composition, which a server that does not tell those apart takes for the same file.
    internal func entry(at url: URL, cancellation: CancellationFlag?, beforeOverwriting: Bool) throws -> RemoteEntry? {
        let target = try resolve(url, cancellation: nil)
        let (session, key, path) = (target.session, target.key, target.path)
        guard let parent = RemotePath.parent(of: path) else {
            return RemoteEntry(name: key.host, isDirectory: true)
        }
        let (parentURL, name) = (key.url(path: parent), RemotePath.name(of: path))
        let isCheap = session.singleLookupsAreCheap
        switch cache.lookUp(name, in: parentURL, lookingForAlike: beforeOverwriting && !isCheap) {
        case .entry(let entry):
            return entry

        case .absent(let hasNameAlike):
            guard beforeOverwriting, isCheap || hasNameAlike else {
                return nil
            }
            return try session.entry(at: path, cancellation: cancellation)

        case .unknown:
            break
        }
        // Where one question costs several commands and a listing, the listing is read once
        // and answers the questions that follow, about the entries that are not there as well.
        if !session.singleLookupsAreCheap,
            (try? read(parentURL, showHidden: true, isVisit: false, cancellation: cancellation) { _ in true }) != nil
        {
            switch cache.lookUp(name, in: parentURL, lookingForAlike: false) {
            case .entry(let entry):
                return entry

            case .absent:
                return nil

            case .unknown:
                break
            }
        }
        return try session.entry(at: path, cancellation: cancellation)
    }

    /// The item at a location; nil when nothing is there or the server cannot be asked.
    public func item(at url: URL) -> FileItem? {
        item(at: url, cancellation: nil)
    }

    /// The item at a location; nil when nothing is there, the server cannot be asked or `cancellation` is set.
    public func item(at url: URL, cancellation: CancellationFlag) -> FileItem? {
        item(at: url, cancellation: Optional(cancellation))
    }

    /// The item at a location, asked with `cancellation` when there is one.
    private func item(at url: URL, cancellation: CancellationFlag?) -> FileItem? {
        guard cancellation?.isCancelled != true,
            let entry = try? entry(at: url, cancellation: cancellation, beforeOverwriting: false),
            let key = ServerKey(url),
            cancellation?.isCancelled != true
        else { return nil }
        let path = RemotePath.of(url)
        guard let parent = RemotePath.parent(of: path) else {
            return FileItem(url: key.url(), name: key.host, kind: .directory, stat: .init(permissions: 0o755))
        }
        var named = entry
        named.name = RemotePath.name(of: path)
        return named.item(in: key.url(path: parent))
    }

    /// The folder that holds `directory`, worked out from the address; nil for the root of a server.
    public func parent(of directory: URL) -> URL? {
        guard let key = ServerKey(directory), let parent = RemotePath.parent(of: RemotePath.of(directory)) else {
            return nil
        }
        return key.url(path: parent)
    }

    /// The top of a server, known from the address alone: no climbing through the path.
    public func root(of url: URL) -> URL {
        guard let key = ServerKey(url) else {
            return url
        }
        return key.url()
    }

    /// Opens the file at `url` for reading from the server.
    public func read(_ url: URL) throws -> any FileReader {
        let target = try resolve(url, cancellation: nil)
        return try target.session.openRead(target.path, cancellation: nil)
    }

    /// Opens the file at `url` for reading; setting `cancellation` ends every wait for the server.
    public func read(_ url: URL, cancellation: CancellationFlag) throws -> any FileReader {
        let target = try resolve(url, cancellation: cancellation)
        return try target.session.openRead(target.path, cancellation: cancellation)
    }

    // MARK: Surroundings

    /// `ftp://host:port/path`, with the names as they are (no percent signs).
    public func displayPath(_ url: URL) -> String {
        guard let key = ServerKey(url) else {
            return url.absoluteString
        }
        return key.description + RemotePath.of(url)
    }

    /// Reads what `displayPath` writes, and addresses as the user types them (spec 11 › Address
    /// and URL syntax).
    ///
    /// A user name and password in the text go to the connection; the returned URL is without them.
    public func location(from text: String) -> URL? {
        let lowered = text.lowercased()
        let prefixes = scheme == "ftps" ? ["ftps://", "ftpes://", "ftpis://"] : [scheme + "://"]
        guard let prefix = prefixes.first(where: lowered.hasPrefix), let address = ServerAddress(text),
            address.scheme == scheme
        else { return nil }
        // Reading a location only says how to log in, should the server be used. It is not the
        // user's wish to connect (the text may come from a file), so `announce` is told nothing
        // of the kind, and it leaves a session alone that is in the middle of its login.
        if address.user != nil || prefix != scheme + "://", !center.isConnected(address.key) {
            center.announce(
                ConnectionProfile(key: address.key, tls: address.tls, user: address.user, password: address.password)
            )
        }
        return address.url
    }

    /// Everything that comes from a server came from elsewhere: the mark a browser puts on
    /// its downloads (`com.apple.quarantine`), so that the system checks a program, an
    /// installer or a script fetched from a server before it first runs.
    ///
    /// Whoever copies a file from here to a disk asks for it and puts it on the copy.
    public func quarantine(of url: URL) -> Data? {
        guard let key = ServerKey(url), key.scheme == scheme else {
            return nil
        }
        return Self.quarantineMark(agent: center.agentName, at: Date())
    }

    /// The connected servers, for the volume list.
    public func places() -> [Place] {
        center.connected.filter { $0.key.scheme == scheme }
            .map { profile in
                Place(
                    name: profile.title,
                    url: profile.key.url(path: center.lastPath(on: profile.key) ?? "/"),
                    kind: .externalDisk
                )
            }
    }

    /// The server a location is on, by the name of its connection (or its address), as a volume that is not local.
    public func volume(of url: URL) -> VolumeInfo? {
        guard let key = ServerKey(url) else {
            return nil
        }
        return VolumeInfo(name: center.profile(of: key)?.title ?? key.description, isLocal: false)
    }

    deinit {
        // Nothing to release.
    }
}

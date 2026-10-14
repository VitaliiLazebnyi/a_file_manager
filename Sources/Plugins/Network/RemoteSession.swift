import AFMKernel
import Foundation

/// How file contents travel (spec 11 › Transfer modes).
public enum TransferMode: Int, CaseIterable {
    /// Byte for byte.
    case binary = 0
    /// Line ends are converted between the server's and the Mac's.
    case text = 1
    /// Text for the file types listed in the preferences, binary for the rest.
    case automatic = 2

    public var title: String {
        switch self {
        case .binary: return "Binary (archives, doc etc.)"
        case .text: return "Text (plain text, html, etc.)"
        case .automatic: return "Automatic"
        }
    }
}

/// The user's network preferences as the connections need them. The settings store belongs to
/// the main thread, so its values are copied here whenever they change; this copy is read from
/// any thread.
public final class NetworkOptions {
    public struct Values {
        public var passiveByDefault = true
        /// Seconds between two NOOPs on an idle connection; 0 sends none.
        public var keepAliveInterval: TimeInterval = 60
        public var transferMode = TransferMode.binary
        /// How many connections to one server serve listings and commands at the same time.
        public var parallelConnections = 3
        public var textFileMasks = NetworkOptions.defaultTextMasks
        public var anonymousPassword = NetworkOptions.defaultAnonymousPassword
        public var timeout: TimeInterval = 30

        public init() {}
    }

    public static let defaultTextMasks = "*.txt *.htm* *.xml *.css *.js *.json *.md *.csv *.ini *.sh *.php *.py *.pl"
    public static let defaultAnonymousPassword = "anonymous@example.com"

    private let lock = NSLock()
    private var current = Values()

    public init() {}

    public var values: Values {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            current = newValue
            lock.unlock()
        }
    }

    /// Whether a file of this name is transferred as text.
    func transfersAsText(_ name: String) -> Bool {
        let values = self.values
        switch values.transferMode {
        case .binary: return false
        case .text: return true
        case .automatic: return FileMask(values.textFileMasks).matches(name)
        }
    }
}

/// How to reach and log in to one server: a saved connection, a quick connection, or what a
/// typed URL said.
public struct ConnectionProfile {
    public var key: ServerKey
    /// The name of the saved connection this came from.
    public var name: String?
    public var savedID: UUID?
    public var tls: TLSMode
    /// Nil: not known yet; the user is asked unless `anonymous` is set.
    public var user: String?
    public var password: String?
    public var anonymous: Bool
    /// Nil: as the preferences say.
    public var passive: Bool?
    public var encoding: NameEncoding
    /// Where to start; nil is the folder the login leads to.
    public var remoteDirectory: String?
    public var initCommands: [String]
    public var usesMLSD: Bool?
    /// True for a server nobody chose to connect to: its address stood in a tab, a list or a
    /// link, and nothing is known of it. The user is asked before the first login.
    public var asksBeforeConnecting = false

    public init(
        key: ServerKey, name: String? = nil, savedID: UUID? = nil, tls: TLSMode? = nil, user: String? = nil,
        password: String? = nil,
        anonymous: Bool = false, passive: Bool? = nil, encoding: NameEncoding = .automatic,
        remoteDirectory: String? = nil,
        initCommands: [String] = [], usesMLSD: Bool? = nil
    ) {
        self.key = key
        self.name = name
        self.savedID = savedID
        // An `ftps:` address that says nothing more: implicit on the port reserved for it, else explicit.
        self.tls = tls ?? (key.scheme == "ftps" ? (key.port == 990 ? .implicit : .explicit) : .none)
        self.user = user
        self.password = password
        self.anonymous = anonymous
        self.passive = passive
        self.encoding = encoding
        self.remoteDirectory = remoteDirectory
        self.initCommands = initCommands
        self.usesMLSD = usesMLSD
    }

    /// What the server is called in titles and the volume list.
    public var title: String { name ?? key.description }
}

/// A user name and password the user typed while connecting.
public struct Credentials {
    public var user: String
    public var password: String
    /// The user wants the password kept for the saved connection. It is stored once the
    /// server has accepted it (`SessionEnvironment.rememberPassword`), not before.
    public var remember: Bool

    public init(user: String, password: String, remember: Bool = false) {
        self.user = user
        self.password = password
        self.remember = remember
    }
}

/// What connections need from the program around them: the preferences, the certificates the
/// user accepted, and a way to ask the user. The questions may be asked from any thread and
/// block until they are answered.
public final class SessionEnvironment {
    public let options: NetworkOptions
    public let trust: CertificateTrust
    /// Asks for the user name and password of a server; `message` says why (the first time, or
    /// what the server answered to the last attempt). Nil when the user gives up.
    public var askCredentials: (_ profile: ConnectionProfile, _ message: String) -> Credentials? = { _, _ in nil }
    /// Shows a certificate the system does not trust; true when the user accepts it. The
    /// answer is recorded in `trust` by whoever asks.
    public var askToTrust: (_ profile: ConnectionProfile, _ certificate: CertificateInfo) -> Bool = { _, _ in false }
    /// Shows a certificate that differs from the ones accepted for this server before
    /// (`known`, their fingerprints): the sign of somebody in the middle, or of a server that
    /// renewed its certificate. True when the user accepts the new one in place of the old;
    /// whoever asks records that with `CertificateTrust.replace`. Refused unless set.
    public var askToTrustChanged:
        (_ profile: ConnectionProfile, _ certificate: CertificateInfo, _ known: [String]) -> Bool = { _, _, _ in false }
    /// Asks whether to connect to a server nobody chose (`ConnectionProfile.asksBeforeConnecting`).
    public var askToConnect: (_ profile: ConnectionProfile) -> Bool = { _ in true }
    /// Asks whether to send a password over a connection that is not encrypted (plain FTP).
    public var askToSendPasswordUnprotected: (_ profile: ConnectionProfile) -> Bool = { _ in true }
    /// A server on this machine itself (`localhost`, `127.0.0.1`) is not asked about: nothing
    /// sent there crosses a network. Tests set this to ask all the same.
    public var asksAboutUnprotectedLoopback = false
    /// Stores the password the user asked to keep, after the server accepted it. Called on the
    /// connecting thread.
    public var rememberPassword: (_ profile: ConnectionProfile, _ password: String) -> Void = { _, _ in }
    /// Asks a question of the secure shell (a host key to confirm, the passphrase of a key).
    public var askSecret: (_ profile: ConnectionProfile, _ question: String, _ isSecret: Bool) -> String? = { _, _, _ in
        nil
    }
    /// After the user refused a password or a certificate, further attempts to connect to that
    /// server fail for this many seconds without asking again: one click on a folder leads to
    /// several questions to the file system, and the user answered once.
    public var declineMemory: TimeInterval = 5
    /// Receives the dialogue with the servers, line by line, from any thread.
    public var log: (String) -> Void = { _ in }

    public init(options: NetworkOptions = NetworkOptions(), trust: CertificateTrust = CertificateTrust()) {
        self.options = options
        self.trust = trust
    }
}

/// A live connection to one server, whatever protocol it speaks. The file-system provider
/// translates between URLs and the paths these methods take.
///
/// **Threading.** Every method may be called from several threads at once and blocks until
/// the server has answered.
protocol RemoteSession: AnyObject {
    var profile: ConnectionProfile { get }
    /// Connects if necessary and returns the directory the login leads to.
    func connect(cancellation: CancellationFlag?) throws -> String
    /// True once a login has succeeded.
    var isConnected: Bool { get }
    /// True while a login is under way (also while it waits for the user's answer).
    var isConnecting: Bool { get }
    /// A set `cancellation` ends the call soon, by throwing `NetworkError.cancelled`, and leaves
    /// the connection in a state it can be used from again, or gone. The same goes for the calls below.
    func list(_ path: String, showHidden: Bool, cancellation: CancellationFlag?, receive: ([RemoteEntry]) -> Bool)
        throws
    /// The entry at a path; nil when nothing is there.
    func entry(at path: String, cancellation: CancellationFlag?) throws -> RemoteEntry?
    /// The flag of the three calls that open a file covers the opening only; the reader or writer
    /// is ended with its own `interrupt`.
    func openRead(_ path: String, cancellation: CancellationFlag?) throws -> FileReader
    /// Starts writing a file that does not exist yet.
    func openWrite(_ path: String, cancellation: CancellationFlag?) throws -> FileWriter
    /// Whether a file of this name can be continued with `openAppend`. Answers at once, from what
    /// is known; a server that is not known yet is believed to.
    func canAppend(_ path: String) -> Bool
    /// Continues an existing file: cut to `offset` bytes when given (throws when it is shorter),
    /// else at its end. `size` is the length the file has when the writer starts.
    func openAppend(_ path: String, at offset: Int64?, cancellation: CancellationFlag?) throws -> (
        writer: FileWriter, size: Int64
    )
    /// `handler` is called, from any thread, when the session finds out after a listing where a
    /// link of it leads: the path of the link, and whether it leads to a folder. A session that
    /// tells at once ignores it.
    func onLinkResolved(_ handler: @escaping (_ path: String, _ isDirectory: Bool) -> Void)
    /// The four calls that change something take the caller's flag as well: the wait for a
    /// connection, for another thread's login and for the server's reply ends when it is set
    /// (Cancel in the progress window), with `NetworkError.cancelled`. A command that was
    /// already sent may have been carried out all the same.
    func makeDirectory(_ path: String, cancellation: CancellationFlag?) throws
    /// Removes a file, a link or an empty directory. `isDirectory` is what the caller knows.
    func remove(_ path: String, isDirectory: Bool?, cancellation: CancellationFlag?) throws
    /// Renames. `replacing` asks for an existing file at the destination to be replaced in the
    /// same step where the protocol can say so (SFTP); whether a plain rename replaces depends
    /// on the server. A server that refuses throws what it said (`NetworkError.refused`,
    /// `SFTPError`); nothing is removed to make room.
    func rename(_ source: String, to destination: String, replacing: Bool, cancellation: CancellationFlag?) throws
    func setAttributes(_ attributes: FileAttributes, of path: String, cancellation: CancellationFlag?) throws
    /// Closes every connection, also those in use.
    func disconnect()
    /// False when asking about one entry costs much more than listing its directory, which the
    /// file system then does once and remembers.
    var singleLookupsAreCheap: Bool { get }
}

extension RemoteSession {
    var singleLookupsAreCheap: Bool { true }
    var isConnecting: Bool { false }
    func rename(_ source: String, to destination: String) throws {
        try rename(source, to: destination, replacing: false, cancellation: nil)
    }
    func makeDirectory(_ path: String) throws { try makeDirectory(path, cancellation: nil) }
    func remove(_ path: String, isDirectory: Bool?) throws {
        try remove(path, isDirectory: isDirectory, cancellation: nil)
    }
    func rename(_ source: String, to destination: String, replacing: Bool) throws {
        try rename(source, to: destination, replacing: replacing, cancellation: nil)
    }
    func setAttributes(_ attributes: FileAttributes, of path: String) throws {
        try setAttributes(attributes, of: path, cancellation: nil)
    }
    func canAppend(_: String) -> Bool { false }
    func onLinkResolved(_: @escaping (_ path: String, _ isDirectory: Bool) -> Void) {}
    func openAppend(_: String, at _: Int64?, cancellation _: CancellationFlag?) throws -> (
        writer: FileWriter, size: Int64
    ) {
        throw FileSystemError.notSupported("Continuing a file on this server")
    }

    func list(_ path: String, showHidden: Bool, receive: ([RemoteEntry]) -> Bool) throws {
        try list(path, showHidden: showHidden, cancellation: nil, receive: receive)
    }
    func entry(at path: String) throws -> RemoteEntry? { try entry(at: path, cancellation: nil) }
    func openRead(_ path: String) throws -> FileReader { try openRead(path, cancellation: nil) }
    func openWrite(_ path: String) throws -> FileWriter { try openWrite(path, cancellation: nil) }
}

/// Where the work runs that waits for a server and that nobody waits for: the clean-up of an
/// abandoned transfer, the goodbye of a connection that is closed, the questions about links
/// after a listing, the keep-alive. The thread that caused it (possibly the main thread) goes
/// on at once.
///
/// A few threads of its own, not a dispatch queue: every piece of work may sit until a time
/// limit runs out when a server has stopped answering, and work that blocks on a dispatch
/// queue takes a thread from the pool the whole program shares. Here at most `mostThreads`
/// threads ever wait; what does not find a free one waits in line, so a dead server cannot
/// pile up threads however many transfers are dropped.
///
/// Work belongs to a lane (a session, a channel), and at most `mostPerLane` pieces of one
/// lane run at the same time: a server that has stopped answering holds up the work of its
/// own connection and never that of another server, whose connections would otherwise come
/// back to their pool only after the dead one's time limits.
enum Background {
    private struct Piece {
        let lane: ObjectIdentifier?
        let work: () -> Void
    }

    private static let condition = NSCondition()
    private static var waiting: [Piece] = []
    private static var threads = 0
    private static var idle = 0
    private static var running = 0
    private static var runningIn: [ObjectIdentifier: Int] = [:]
    private static var waitingIn: [ObjectIdentifier: Int] = [:]
    static let mostThreads = 24
    static let mostPerLane = 3

    static func run(lane: AnyObject? = nil, _ work: @escaping () -> Void) {
        let lane = lane.map(ObjectIdentifier.init)
        condition.lock()
        waiting.append(Piece(lane: lane, work: work))
        if let lane { waitingIn[lane, default: 0] += 1 }
        if idle > 0 {
            // Every sleeper looks: the one that is woken must be one that may take this piece.
            condition.broadcast()
        } else if threads < mostThreads, lane.map({ runningIn[$0, default: 0] < mostPerLane }) ?? true {
            threads += 1
            let thread = Thread { Self.serve() }
            thread.name = "afm.network.background"
            thread.qualityOfService = .utility
            thread.start()
        }
        condition.unlock()
    }

    /// The first piece in line whose lane has room. Called with the lock held.
    private static func takeNext() -> Piece? {
        guard
            let index = waiting.firstIndex(where: { piece in
                piece.lane.map { runningIn[$0, default: 0] < mostPerLane } ?? true
            })
        else { return nil }
        let piece = waiting.remove(at: index)
        if let lane = piece.lane {
            runningIn[lane, default: 0] += 1
            waitingIn[lane] = waitingIn[lane].flatMap { $0 > 1 ? $0 - 1 : nil }
        }
        running += 1
        return piece
    }

    private static func serve() {
        condition.lock()
        var waitedInVain = false
        while true {
            if let piece = takeNext() {
                condition.unlock()
                piece.work()
                condition.lock()
                running -= 1
                if let lane = piece.lane { runningIn[lane] = runningIn[lane].flatMap { $0 > 1 ? $0 - 1 : nil } }
                condition.broadcast()
                waitedInVain = false
                continue
            }
            // What may still wait is behind its own lane's limit, and the threads of that lane take it.
            if waitedInVain {
                threads -= 1
                condition.unlock()
                return
            }
            idle += 1
            waitedInVain = !condition.wait(until: Date().addingTimeInterval(10))
            idle -= 1
        }
    }

    /// Waits until nothing is running or waiting, `timeout` seconds at most; for tests.
    @discardableResult
    static func waitUntilIdle(timeout: TimeInterval) -> Bool {
        wait(timeout) { running == 0 && waiting.isEmpty }
    }

    /// Waits until nothing of this lane is running or waiting, `timeout` seconds at most; for tests.
    @discardableResult
    static func waitUntilIdle(lane: AnyObject, timeout: TimeInterval) -> Bool {
        let lane = ObjectIdentifier(lane)
        return wait(timeout) { runningIn[lane] == nil && waitingIn[lane] == nil }
    }

    private static func wait(_ timeout: TimeInterval, until isDone: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !isDone() {
            guard Date() < deadline else { return false }
            condition.wait(until: min(deadline, Date().addingTimeInterval(0.1)))
        }
        return true
    }

    /// The threads that exist right now, for tests.
    static var threadCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return threads
    }
}

/// Runs `body` with a flag that is set as soon as either of two is: the session's own (set
/// by Disconnect) and the caller's (Cancel in the progress window). Without a caller's flag
/// the session's own is passed as it is.
func withEither<Result>(
    _ own: CancellationFlag, _ callers: CancellationFlag?, _ body: (CancellationFlag) throws -> Result
) rethrows -> Result {
    guard let callers, callers !== own else { return try body(own) }
    let both = CancellationFlag()
    // The registrations are released when the call is over; `both` outlives them.
    let registrations = [own.onCancel { both.cancel() }, callers.onCancel { both.cancel() }]
    defer { withExtendedLifetime(registrations) {} }
    return try body(both)
}

/// A lock that is waited for in short turns, so the wait can end: when `cancellation` is set,
/// when `shouldGiveUp` says so (it returns the error to throw), and at once on the main thread,
/// which must never wait behind a login that may be asking the user something (the question is
/// answered on the main thread).
func lockPatiently(_ lock: NSLock, cancellation: CancellationFlag?, shouldGiveUp: () -> Error?) throws {
    if lock.try() { return }
    if Thread.isMainThread { throw NetworkError.busy("The connection is busy logging in.") }
    while !lock.lock(before: Date().addingTimeInterval(0.1)) {
        if cancellation?.isCancelled == true { throw NetworkError.cancelled }
        if let error = shouldGiveUp() { throw error }
    }
}

/// Converts line ends for transfers in text mode: the network form is CR LF, the Mac's is LF.
/// Runs between the line ends are copied as blocks.
struct LineEndConverter {
    private var pendingCR = false

    /// Network to Mac. A CR at the end of a block waits for the next block.
    mutating func toLocal(_ data: Data) -> Data {
        var result = Data(capacity: data.count)
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
            let count = bytes.count
            var start = 0
            if pendingCR {
                pendingCR = false
                if bytes[0] != 0x0A { result.append(0x0D) }
            }
            var index = 0
            while index < count, let found = memchr(base + index, 0x0D, count - index) {
                let cr = base.distance(to: UnsafeRawPointer(found))
                // The CR itself stays out of the run; it is dropped before an LF and kept before anything else.
                result.append(base.assumingMemoryBound(to: UInt8.self) + start, count: cr - start)
                if cr + 1 == count {
                    pendingCR = true
                    start = count
                    index = count
                } else {
                    if bytes[cr + 1] != 0x0A { result.append(0x0D) }
                    start = cr + 1
                    index = cr + 1
                }
            }
            result.append(base.assumingMemoryBound(to: UInt8.self) + start, count: count - start)
        }
        return result
    }

    /// What is left when the data ends on a CR.
    mutating func finishLocal() -> Data {
        defer { pendingCR = false }
        return pendingCR ? Data([0x0D]) : Data()
    }

    /// Mac to network: every LF that does not already follow a CR gets one.
    mutating func toNetwork(_ data: Data) -> Data {
        var result = Data(capacity: data.count + data.count / 32)
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
            let count = bytes.count
            let pointer = base.assumingMemoryBound(to: UInt8.self)
            var start = 0
            var index = 0
            while index < count, let found = memchr(base + index, 0x0A, count - index) {
                let lf = base.distance(to: UnsafeRawPointer(found))
                let followsCR = lf == 0 ? pendingCR : bytes[lf - 1] == 0x0D
                if !followsCR {
                    result.append(pointer + start, count: lf - start)
                    result.append(0x0D)
                    start = lf
                }
                index = lf + 1
            }
            result.append(pointer + start, count: count - start)
            pendingCR = bytes[count - 1] == 0x0D
        }
        return result
    }
}

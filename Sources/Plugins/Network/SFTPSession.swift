import AFMKernel
import Foundation

/// What a question of `ssh` is, told by the words ssh itself puts around it. A server can make
/// ssh show any text it likes (keyboard-interactive logins, and a jump host can do the same),
/// so a question is only taken for ssh's own when it has exactly the shape ssh gives it, and
/// everything a server may have written is shown to the user as the server's.
enum SSHQuestion: Equatable {
    /// `user@host's password:`, asked by ssh itself.
    case password(user: String, host: String)
    /// `(user@host) text`: a keyboard-interactive login. The text is the server's.
    case server(user: String, host: String, text: String)
    /// `Enter passphrase for key '…':`, about a key on this Mac.
    case passphrase
    /// An unknown host key, to be answered with `yes` or `no`.
    case hostKey
    case other

    init(_ question: String) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        /// `user@host`, cut at the last `@`: a host has none, a user name may.
        func login(_ text: Substring) -> (user: String, host: String)? {
            guard let at = text.lastIndex(of: "@") else { return nil }
            let host = String(text[text.index(after: at)...]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .lowercased()
            guard at > text.startIndex, !host.isEmpty, !host.contains(where: { $0.isWhitespace }) else { return nil }
            return (String(text[..<at]), host)
        }
        if text.hasPrefix("("), let close = text.range(of: ") "),
            let login = login(text[text.index(after: text.startIndex)..<close.lowerBound])
        {
            self = .server(user: login.user, host: login.host, text: String(text[close.upperBound...]))
        } else if text.hasPrefix("("), text.hasSuffix(")"), let login = login(text.dropFirst().dropLast()) {
            self = .server(user: login.user, host: login.host, text: "")
        } else if text.hasPrefix("The authenticity of host "), text.contains("(yes/no") {
            self = .hostKey
        } else if text.hasPrefix("Please type 'yes'") {
            self = .hostKey
        } else if text.hasPrefix("Enter passphrase for ") || text.hasPrefix("Enter PIN for ") {
            self = .passphrase
        } else if let end = text.range(of: "'s password:", options: [.caseInsensitive, .backwards]),
            end.upperBound == text.endIndex,
            !text.contains("\n"), let login = login(text[..<end.lowerBound])
        {
            self = .password(user: login.user, host: login.host)
        } else {
            self = .other
        }
    }

    /// The question as the user is shown it: what a server wrote is marked as the server's, so
    /// it cannot pass for a question of this Mac (`Enter passphrase for key …`).
    func shown(_ question: String) -> String {
        switch self {
        case .server(_, let host, let text):
            return "The server \(host) asks (this text comes from the server):\n\n\(text)"

        case .other:
            return "The secure shell passes on this question, which may come from the server:\n\n\(question)"

        case .password, .passphrase, .hostKey:
            return question
        }
    }
}

/// A connection to an SFTP server (the secure shell's file transfer). The system's own
/// `/usr/bin/ssh` makes the connection, so everything the user has set up for it works: keys,
/// the agent, `~/.ssh/config`, known hosts, jump hosts. A password, the passphrase of a key
/// and the question about an unknown host key are asked through `AskpassHelper`.
///
/// **Threading.** Safe from any thread. One `SFTPChannel` serves all threads at once; it is
/// opened on first use and opened again when it broke.
///
/// All mutable state is guarded by `lock`.
final class SFTPSession: RemoteSession, @unchecked Sendable {
    private let environment: SessionEnvironment
    private let transport: SFTPTransport?
    private let lock = NSLock()
    /// Held while the channel is being opened, so several threads share one login.
    private let connectLock = NSLock()
    private var currentProfile: ConnectionProfile
    private var channel: SFTPChannel?
    /// The channel of a login that is under way, so `disconnect` can end it.
    private var opening: SFTPChannel?
    private var hasConnected = false
    private var isClosed = false
    private var isAsking = false
    private var home = "/"
    private var declined: (error: any Error, at: Date)?
    private var mayConnect = false
    /// Set by `disconnect`: ends the waits of this session that have no flag of their own.
    fileprivate let closing = CancellationFlag()
    /// The names of this server that are written back as they came.
    private let names = NameMemory()
    /// How long a thread waits for another thread's login that makes no progress, nil for the
    /// usual time (see `open`). Tests shorten it.
    var stallLimit: TimeInterval? {
        get { lock.withLock { stallTime } }
        set { lock.withLock { stallTime = newValue } }
    }
    private var stallTime: TimeInterval?

    /// The largest piece read or written with one request; every server takes this much.
    fileprivate static let blockSize = 32_768
    /// The most requests of a transfer that are under way at the same time. With 32 KB each this
    /// keeps 2 MB on the way, which is what a fast line with a long delay needs; a slow line
    /// gets fewer (`TransferWindow`).
    fileprivate static let window = 64

    init(profile: ConnectionProfile, environment: SessionEnvironment, transport: SFTPTransport? = nil) {
        currentProfile = profile
        self.environment = environment
        self.transport = transport
    }

    var profile: ConnectionProfile {
        lock.lock()
        defer { lock.unlock() }
        return currentProfile
    }

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasConnected && !isClosed
    }

    var isConnecting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return opening != nil && !isClosed
    }

    fileprivate var timeout: TimeInterval { environment.options.values.timeout }

    // MARK: Connecting

    /// The arguments for `ssh` that open the SFTP subsystem on the profile's server.
    static func sshArguments(for profile: ConnectionProfile, options: NetworkOptions.Values) -> [String] {
        // ssh notices a dead connection by its own probes, also when the user wants no
        // keep-alive of ours: without them it would never end on a line that swallows everything.
        let probe = options.keepAliveInterval > 0 ? Int(options.keepAliveInterval) : max(15, Int(options.timeout))
        var arguments = [
            "-o", "ConnectTimeout=\(Int(options.timeout))", "-o", "NumberOfPasswordPrompts=1", "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes",
            // Nothing but the file transfer: no command, no terminal, and not through (or as)
            // a shared connection of the user's, which ending this one would take down.
            "-o", "RemoteCommand=none", "-o", "PermitLocalCommand=no", "-o", "ControlMaster=no", "-o",
            "ControlPath=none",
            "-o", "RequestTTY=no",
            // Errors only: the server's banner is not among them, so it cannot pass for one.
            "-o", "LogLevel=ERROR",
            "-o", "ServerAliveInterval=\(probe)", "-o", "ServerAliveCountMax=3", "-p", String(profile.key.port)
        ]
        if let user = profile.user, !user.isEmpty { arguments += ["-l", user] }
        // After `--` nothing is taken for an option, whatever the host is called.
        return arguments + ["-T", "-s", "--", profile.key.host, "sftp"]
    }

    /// Whether a question of ssh is the request for the password of this profile's login. ssh
    /// asks `user@host's password:` (or `(user@host) Password:` for keyboard-interactive logins),
    /// and every `ssh` that runs on behalf of this connection asks through the same helper: a
    /// jump host (`ProxyJump`) would be given the password of the target server if the first
    /// request for a password were answered whoever it comes from. A question that names another
    /// login or host is passed on to the user, and so is one that names none: who asks it
    /// cannot be told.
    static func asksForPassword(_ question: String, of profile: ConnectionProfile) -> Bool {
        let (user, host): (String, String)
        switch SSHQuestion(question) {
        case .password(let asked, let server):
            (user, host) = (asked, server)

        case .server(let asked, let server, let text):
            let lowered = text.lowercased()
            guard lowered.contains("password"), !lowered.contains("passphrase") else { return false }
            (user, host) = (asked, server)

        case .passphrase, .hostKey, .other:
            return false
        }
        if let own = profile.user, !own.isEmpty, own != user { return false }
        return host == ServerKey.bare(profile.key.host).lowercased()
    }

    /// The channel, opened if necessary.
    private func open(cancellation: CancellationFlag?) throws -> SFTPChannel {
        // The usual case takes no lock that a login holds.
        lock.lock()
        if let existing = channel, !existing.isClosed, !isClosed {
            lock.unlock()
            return existing
        }
        lock.unlock()
        // Another thread may be logging in, perhaps waiting for the user; this one can still be
        // cancelled, ends with the session, and gives up when the login makes no progress.
        let began = Date()
        let timeout = environment.options.values.timeout
        let patience = stallLimit ?? max(60, 2 * timeout) + timeout + 30
        try lockPatiently(connectLock, cancellation: cancellation) {
            self.lock.lock()
            defer { self.lock.unlock() }
            if self.isClosed { return NetworkError.notConnected(self.currentProfile.key.description) }
            // The time the user takes to answer a question does not count.
            if !self.isAsking, Date().timeIntervalSince(began) > patience {
                return NetworkError.busy("Another login to \(self.currentProfile.key.description) is still under way.")
            }
            return nil
        }
        defer { connectLock.unlock() }
        lock.lock()
        let (existing, closed, recent, asksFirst) = (
            channel, isClosed, declined, currentProfile.asksBeforeConnecting && !mayConnect
        )
        let profile = currentProfile
        lock.unlock()
        if closed { throw NetworkError.notConnected(profile.key.description) }
        if let existing, !existing.isClosed { return existing }
        if let recent, Date().timeIntervalSince(recent.at) < environment.declineMemory { throw recent.error }

        func asking<Answer>(_ question: () -> Answer) -> Answer {
            lock.lock()
            isAsking = true
            lock.unlock()
            defer {
                lock.lock()
                isAsking = false
                lock.unlock()
            }
            return question()
        }
        func decline(_ error: any Error) -> any Error {
            lock.lock()
            declined = (error, Date())
            lock.unlock()
            return error
        }
        if asksFirst {
            guard asking({ environment.askToConnect(profile) }) else { throw decline(NetworkError.cancelled) }
            lock.lock()
            mayConnect = true
            lock.unlock()
        }

        // The stored password is tried once. When the server does not take it, the login is
        // made again and the user is asked; an answer that works takes the stored one's place.
        func logIn(_ profile: ConnectionProfile, storedWasRefused: Bool) throws -> SFTPChannel {
            var typedPassword: String?
            var offeredPassword = false
            var refused = false
            do {
                let created = try start(profile, cancellation: cancellation) { helper, question in
                    let kind = SSHQuestion(question.text)
                    if question.kind == .notice {
                        // Nothing to answer (touch the security key): said in the log.
                        environment.log(question.text)
                        helper.reply("", to: question)
                        return true
                    }
                    let isConfirmation = question.kind == .confirm || kind == .hostKey
                    let isPassword = Self.asksForPassword(question.text, of: profile)
                    if !isConfirmation, !offeredPassword, isPassword, let password = profile.password {
                        // The stored password answers the first request for this server's password.
                        offeredPassword = true
                        helper.reply(password, to: question)
                        return true
                    }
                    guard
                        let answer = asking({
                            environment.askSecret(profile, kind.shown(question.text), !isConfirmation)
                        })
                    else {
                        refused = true
                        return false
                    }
                    if isPassword { typedPassword = answer }
                    helper.reply(answer, to: question)
                    return true
                }
                environment.log("Logged in to \(profile.key.description), at \(created.home)")
                lock.lock()
                if isClosed {
                    // Disconnected while the login ran: the channel is nobody's.
                    opening = nil
                    lock.unlock()
                    created.channel.close()
                    throw NetworkError.notConnected(profile.key.description)
                }
                channel = created.channel
                opening = nil
                hasConnected = true
                if created.home.hasPrefix("/") { home = RemotePath.normalized(created.home) }
                if let typedPassword { currentProfile.password = typedPassword }
                lock.unlock()
                // A password typed in place of a stored one that failed is the stored one now.
                if storedWasRefused, let typedPassword { environment.rememberPassword(profile, typedPassword) }
                return created.channel
            } catch {
                lock.lock()
                opening = nil
                lock.unlock()
                if case NetworkError.loginFailed = error, offeredPassword, !storedWasRefused, !refused,
                    cancellation?.isCancelled != true
                {
                    var withoutPassword = profile
                    withoutPassword.password = nil
                    return try logIn(withoutPassword, storedWasRefused: true)
                }
                // Remembered as a refusal only when the user said no to a question.
                throw refused ? decline(error) : error
            }
        }
        return try logIn(profile, storedWasRefused: false)
    }

    /// Starts ssh, answers its questions through `answer`, and returns the channel and the
    /// directory the login leads to.
    private func start(
        _ profile: ConnectionProfile,
        cancellation: CancellationFlag?,
        answer: (AskpassHelper, AskpassHelper.Question) -> Bool
    ) throws -> (channel: SFTPChannel, home: String) {
        let options = environment.options.values
        let askpass: AskpassHelper?
        let created: SFTPChannel
        if let transport {
            askpass = transport.asksQuestions ? try AskpassHelper() : nil
            created = SFTPChannel(
                executable: transport.executable,
                arguments: transport.arguments,
                environment: askpass?.environment ?? [:],
                writeTimeout: max(10, options.timeout),
                names: names
            )
        } else {
            guard profile.user?.hasPrefix("-") != true else {
                throw NetworkError.loginFailed("The user name is not valid.")
            }
            let helper = try AskpassHelper()
            askpass = helper
            created = SFTPChannel(
                executable: "/usr/bin/ssh",
                arguments: Self.sshArguments(for: profile, options: options),
                environment: helper.environment,
                writeTimeout: max(10, options.timeout),
                names: names
            )
        }
        lock.lock()
        let closed = isClosed
        if !closed { opening = created }
        lock.unlock()
        if closed { throw NetworkError.notConnected(profile.key.description) }
        environment.log("Connect to: \(profile.key.description)")
        do {
            // ssh has its own time limit for reaching the server; ours is for a login that hangs.
            try created.start(timeout: options.timeout + 30, cancellation: cancellation ?? closing) {
                guard let askpass, let question = askpass.pendingQuestion() else { return true }
                return answer(askpass, question)
            }
            let packet = try created.request(
                .realpath,
                timeout: options.timeout,
                cancellation: cancellation ?? closing
            ) { $0.string(".") }
            var names = try packet.expect(.name)
            _ = try names.u32()
            return (created, try names.string())
        } catch {
            if case NetworkError.connectionLost = error {
                // ssh ended: what it printed says why (no route, wrong password, host key changed).
                // Its last line may still be on its way when the end is noticed, so it is waited for.
                let said = created.errorMessageAtTheEnd()
                created.close()
                throw NetworkError.loginFailed(said.isEmpty ? "The secure shell ended without a message." : said)
            }
            created.close()
            throw error
        }
    }

    /// Runs requests on the channel. A channel that was dropped while idle is opened again.
    fileprivate func perform<Result>(cancellation: CancellationFlag? = nil, _ work: (SFTPChannel) throws -> Result)
        throws -> Result
    {
        try work(try open(cancellation: cancellation))
    }

    func connect(cancellation: CancellationFlag?) throws -> String {
        _ = try open(cancellation: cancellation)
        lock.lock()
        defer { lock.unlock() }
        return home
    }

    /// Returns at once. A login that is under way ends with it: its ssh is stopped too.
    func disconnect() {
        lock.lock()
        isClosed = true
        let (open, starting) = (channel, opening)
        channel = nil
        lock.unlock()
        closing.cancel()
        open?.close()
        starting?.close()
    }

    // MARK: Requests

    private func attributes(
        of path: String,
        following: Bool,
        on channel: SFTPChannel,
        cancellation: CancellationFlag? = nil
    ) throws -> SFTPAttributes? {
        let packet = try channel.request(following ? .stat : .lstat, timeout: timeout, cancellation: cancellation) {
            $0.string(path)
        }
        if packet.statusCode == SFTPError.noSuchFile { return nil }
        var decoder = try packet.expect(.attributes)
        return try decoder.attributes()
    }

    fileprivate func openHandle(
        _ type: SFTPRequest,
        on channel: SFTPChannel,
        cancellation: CancellationFlag? = nil,
        _ build: (inout SFTPEncoder) -> Void
    ) throws -> Data {
        var decoder = try channel.request(type, timeout: timeout, cancellation: cancellation, build).expect(.handle)
        return Data(try decoder.bytes())
    }

    /// Closes a handle whose closing can tell nothing (it was read from, or its transfer was
    /// given up). Never waits: the request is put in line and reaches the server before
    /// whatever is asked next, so a file whose handle is closed here can be removed right after.
    fileprivate func closeHandle(_ handle: Data, on channel: SFTPChannel) {
        channel.sendWithoutAnswer(.close) { $0.bytes(handle) }
    }

    func list(_ path: String, showHidden _: Bool, cancellation: CancellationFlag?, receive: ([RemoteEntry]) -> Bool)
        throws
    {
        try perform(cancellation: cancellation) { channel in
            let handle = try openHandle(.opendir, on: channel, cancellation: cancellation) { $0.string(path) }
            defer { closeHandle(handle, on: channel) }
            var wanted = true
            while wanted {
                let packet = try channel.request(.readdir, timeout: timeout, cancellation: cancellation) {
                    $0.bytes(handle)
                }
                if packet.statusCode == SFTPError.endOfFile { break }
                var decoder = try packet.expect(.name)
                var entries: [RemoteEntry] = []
                for _ in 0..<(try decoder.u32()) {
                    let name = try decoder.name()
                    _ = try decoder.bytes()
                    let attributes = try decoder.attributes()
                    guard RemoteEntry.isSafeName(name.text) else { continue }
                    if NameMemory.needsRemembering(name.text, readAs: name.encoding, sending: .utf8) {
                        names.remember(name.text, encoding: name.encoding)
                    }
                    entries.append(attributes.entry(named: name.text))
                }
                // Whether a link leads to a directory is asked for all links of the batch at
                // once, and all the answers together get the time one answer may take.
                let links = entries.indices.filter { entries[$0].isSymlink }
                var answers: [SFTPChannel.Ticket] = []
                do {
                    for index in links {
                        answers.append(
                            try channel.send(.stat, cancellation: cancellation) {
                                $0.string(RemotePath.join(path, entries[index].name))
                            }
                        )
                    }
                } catch {
                    // The requests that did go out are not waited for any more.
                    answers.forEach(channel.abandon)
                    throw error
                }
                let deadline = Date().addingTimeInterval(timeout)
                for (position, (index, answer)) in zip(links, answers).enumerated() {
                    do {
                        let left = max(0.05, deadline.timeIntervalSinceNow)
                        var target = try channel.wait(for: answer, timeout: left, cancellation: cancellation)
                            .expect(
                                .attributes
                            )
                        entries[index].isDirectory = try target.attributes().isDirectory
                    } catch NetworkError.cancelled {
                        answers[position...].forEach(channel.abandon)
                        throw NetworkError.cancelled
                    } catch NetworkError.connectionLost {
                        answers[position...].forEach(channel.abandon)
                        throw NetworkError.connectionLost
                    } catch {}
                }
                wanted = entries.isEmpty || receive(entries)
            }
        }
    }

    func entry(at path: String, cancellation: CancellationFlag?) throws -> RemoteEntry? {
        let path = RemotePath.normalized(path)
        return try perform(cancellation: cancellation) { channel in
            guard let attributes = try attributes(of: path, following: false, on: channel, cancellation: cancellation)
            else { return nil }
            var entry = attributes.entry(named: path == "/" ? "/" : RemotePath.name(of: path))
            if entry.isSymlink {
                do {
                    if let target = try self.attributes(
                        of: path,
                        following: true,
                        on: channel,
                        cancellation: cancellation
                    ) {
                        entry.isDirectory = target.isDirectory
                    }
                } catch NetworkError.cancelled {
                    throw NetworkError.cancelled
                } catch {}
            }
            return entry
        }
    }

    // The four calls that change something end on the caller's flag and on `closing`, which
    // is set when the session is disconnected.

    func makeDirectory(_ path: String, cancellation: CancellationFlag?) throws {
        try withEither(closing, cancellation) { closing in
            try perform(cancellation: closing) {
                try $0.request(.mkdir, timeout: timeout, cancellation: closing) {
                    $0.string(path)
                    $0.attributes()
                }
                .checkStatus()
            }
        }
    }

    func remove(_ path: String, isDirectory: Bool?, cancellation: CancellationFlag?) throws {
        try withEither(closing, cancellation) { closing in
            try perform(cancellation: closing) { channel in
                var isFolder = isDirectory
                if isFolder == nil {
                    isFolder =
                        try attributes(of: path, following: false, on: channel, cancellation: closing)?.isDirectory
                        ?? false
                }
                try channel.request(isFolder == true ? .rmdir : .remove, timeout: timeout, cancellation: closing) {
                    $0.string(path)
                }
                .checkStatus()
            }
        }
    }

    /// With `replacing`, OpenSSH's extension is used where the server has it: it renames like
    /// the Mac does, an existing file is replaced in the same step. Without, the plain rename
    /// of the protocol, which a server refuses when the destination exists. What the server
    /// answers is thrown as it is (`SFTPError`): a refusal is not turned into "something is in
    /// the way", which only the caller can find out.
    func rename(_ source: String, to destination: String, replacing: Bool, cancellation: CancellationFlag?) throws {
        try withEither(closing, cancellation) { closing in
            try perform(cancellation: closing) { channel in
                if replacing, channel.extensions["posix-rename@openssh.com"] != nil {
                    try channel.request(.extended, timeout: timeout, cancellation: closing) {
                        $0.string("posix-rename@openssh.com")
                        $0.string(source)
                        $0.string(destination)
                    }
                    .checkStatus()
                } else {
                    try channel.request(.rename, timeout: timeout, cancellation: closing) {
                        $0.string(source)
                        $0.string(destination)
                    }
                    .checkStatus()
                }
            }
        }
    }

    func setAttributes(_ attributes: FileAttributes, of path: String, cancellation: CancellationFlag?) throws {
        var changes = SFTPAttributes()
        changes.modified = attributes.modified.map { UInt32(clamping: Int64($0.timeIntervalSince1970)) }
        changes.permissions = attributes.permissions.map { UInt32($0 & 0o7777) }
        try withEither(closing, cancellation) { closing in
            try perform(cancellation: closing) {
                try $0.request(.setstat, timeout: timeout, cancellation: closing) {
                    $0.string(path)
                    $0.attributes(changes)
                }
                .checkStatus()
            }
        }
    }

    func openRead(_ path: String, cancellation: CancellationFlag?) throws -> any FileReader {
        try perform(cancellation: cancellation) { channel in
            let handle = try openHandle(.open, on: channel, cancellation: cancellation) {
                $0.string(path)
                $0.u32(1)
                $0.attributes()
            }
            return SFTPFileReader(session: self, channel: channel, handle: handle)
        }
    }

    func openWrite(_ path: String, cancellation: CancellationFlag?) throws -> any FileWriter {
        try perform(cancellation: cancellation) { channel in
            // Write, create, and fail if the file exists.
            let handle = try openHandle(.open, on: channel, cancellation: cancellation) {
                $0.string(path)
                $0.u32(0x02 | 0x08 | 0x20)
                $0.attributes()
            }
            return SFTPFileWriter(session: self, channel: channel, handle: handle)
        }
    }

    /// Every server can write at any position of a file it has open.
    func canAppend(_: String) -> Bool { true }

    /// Opens the file for writing without creating or emptying it, cuts it to `offset` when it is
    /// longer (`fsetstat` with a size), and writes from there.
    func openAppend(_ path: String, at offset: Int64?, cancellation: CancellationFlag?) throws -> (
        writer: any FileWriter, size: Int64
    ) {
        try perform(cancellation: cancellation) { channel in
            let handle = try openHandle(.open, on: channel, cancellation: cancellation) {
                $0.string(path)
                $0.u32(0x02)
                $0.attributes()
            }
            do {
                var found =
                    try channel.request(.fstat, timeout: timeout, cancellation: cancellation) {
                        $0.bytes(handle)
                    }
                    .expect(.attributes)
                let size = Int64(clamping: try found.attributes().size ?? 0)
                let target = offset ?? size
                guard target >= 0, target <= size else {
                    throw FileSystemError.notSupported("Continuing \(path) at \(target), it has \(size) bytes")
                }
                if target < size {
                    var cut = SFTPAttributes()
                    cut.size = UInt64(target)
                    try channel.request(.fsetstat, timeout: timeout, cancellation: cancellation) {
                        $0.bytes(handle)
                        $0.attributes(cut)
                    }
                    .checkStatus()
                }
                return (
                    SFTPFileWriter(session: self, channel: channel, handle: handle, position: UInt64(target)), target
                )
            } catch {
                closeHandle(handle, on: channel)
                throw error
            }
        }
    }
}

/// How many requests of one transfer are kept under way. More requests make a fast line with a
/// long delay fast; on a slow line they only stand in the way, because everything else on the
/// shared channel (a listing, another file) is answered after them. The window therefore
/// follows what the line carries: about `seconds` worth of data, measured over the transfer
/// so far, between `least` and `SFTPSession.window` requests.
private struct TransferWindow {
    private let started = Date()
    private var bytes = 0
    private static let seconds = 1.5
    private static let least = 2

    mutating func moved(_ count: Int) { bytes += count }

    /// The most requests to keep under way now, for requests of `block` bytes.
    func limit(block: Int) -> Int {
        let elapsed = Date().timeIntervalSince(started)
        // Nothing is known in the first moments; the caller's own slow start applies.
        guard elapsed > 0.25, bytes > 0 else { return SFTPSession.window }
        let wanted = Double(bytes) / elapsed * Self.seconds / Double(max(1, block))
        return max(Self.least, min(SFTPSession.window, Int(wanted.rounded(.up))))
    }
}

/// A file being read over SFTP. A window of read requests is kept under way, also between
/// two calls: when the caller has taken one piece the next ones are already on their way, so
/// the speed does not depend on the delay of one round trip. Nothing is read ahead for the
/// first read after opening or after a jump (a viewer that shows one page asks for one page);
/// from the second read in a row on, the window grows, up to what the line carries
/// (`TransferWindow`). Seeking discards what was read ahead. Used by one thread; `close` and
/// `interrupt` never wait for the server.
///
/// Used by one thread at a time, as `FileReader` allows; `interrupt` only sets the flag, which is
/// safe from any thread.
private final class SFTPFileReader: FileReader, @unchecked Sendable {
    /// One read request: the bytes `offset ..< offset + length` of the file.
    private struct Chunk {
        let offset: UInt64
        let length: Int
        let ticket: SFTPChannel.Ticket
        /// Asks for the rest of a piece the server answered only in part.
        let isRest: Bool
    }

    private let session: SFTPSession
    private let channel: SFTPChannel
    private var handle: Data?
    /// Where the next byte for the caller is.
    private var position: UInt64 = 0
    /// The bytes that start at `position`: an answer that was taken only in part.
    private var leftover = Data()
    /// The requests under way, in file order; the first starts where `leftover` ends.
    private var requests: [Chunk] = []
    /// Where the request after the last one starts.
    private var nextOffset: UInt64 = 0
    private var sawEnd = false
    private var depth = SFTPFileReader.firstDepth
    private static let firstDepth = 4
    /// How many reads followed one another since the file was opened or the position jumped.
    private var readsInARow = 0
    /// How much is asked for with one request: less than the usual block once the server has
    /// shown that it never gives more. A single short answer says nothing (the file may end
    /// there, the server may have been interrupted); the same short length three times in a
    /// row for requests of the full size is the server's limit.
    private var block = SFTPSession.blockSize
    private var shortAnswer: Int?
    private var shortAnswers = 0
    private var window = TransferWindow()
    /// Set by `interrupt`; the waits for answers look at it. Only this reader's requests are
    /// given up, the channel is shared with other transfers and stays open.
    private let abort = CancellationFlag()

    init(session: SFTPSession, channel: SFTPChannel, handle: Data) {
        self.session = session
        self.channel = channel
        self.handle = handle
    }

    deinit {
        // Dropped without `close`: the handle is closed all the same, which never waits.
        guard let handle else { return }
        abandonRequests()
        session.closeHandle(handle, on: channel)
    }

    private func sendRequest(at offset: UInt64, length: Int, isRest: Bool = false, _ handle: Data) throws -> Chunk {
        let ticket = try channel.send(.read, cancellation: abort) {
            $0.bytes(handle)
            $0.u64(offset)
            $0.u32(UInt32(length))
        }
        return Chunk(offset: offset, length: length, ticket: ticket, isRest: isRest)
    }

    /// Tops the window up to `want` requests.
    private func fill(_ want: Int, _ handle: Data) throws {
        while requests.count < want, !sawEnd {
            requests.append(try sendRequest(at: nextOffset, length: block, handle))
            nextOffset += UInt64(block)
        }
    }

    private func abandonRequests() {
        requests.forEach { channel.abandon($0.ticket) }
        requests = []
    }

    /// Forgets everything that was read ahead; the next read starts at `offset`.
    private func rewind(to offset: UInt64) {
        abandonRequests()
        leftover = Data()
        position = offset
        nextOffset = offset
        sawEnd = false
    }

    func read(upToCount count: Int) throws -> Data? {
        if abort.isCancelled { throw NetworkError.cancelled }
        guard let handle, count > 0 else { return nil }
        // Read ahead only for a caller that reads on, and no further than the line carries.
        var ahead = 0
        if readsInARow > 0 {
            depth = min(SFTPSession.window, depth * 2)
            ahead = min(depth, window.limit(block: block))
        }
        readsInARow += 1
        /// How many requests should be under way while `missing` bytes are still wanted.
        func want(_ missing: Int) -> Int {
            let needed = (max(0, missing - leftover.count) + block - 1) / block
            return min(window.limit(block: block), max(ahead, needed))
        }
        var result = Data()
        do {
            try fill(want(count), handle)
            while result.count < count {
                if !leftover.isEmpty {
                    let taken = leftover.prefix(count - result.count)
                    if result.isEmpty { result.reserveCapacity(min(count, max(taken.count, 1 << 20))) }
                    result.append(taken)
                    leftover = leftover.dropFirst(taken.count)
                    position += UInt64(taken.count)
                    continue
                }
                // Whenever more is wanted than `leftover` holds, `fill` has put a request under way
                // for it, so a request is there unless the end was seen.
                guard !sawEnd, let chunk = requests.first else { break }
                let packet: SFTPPacket
                do {
                    packet = try channel.wait(for: chunk.ticket, timeout: session.timeout, cancellation: abort)
                } catch {
                    // The answer is not coming, or the channel is gone. The window is dropped
                    // with it so that a later read starts clean.
                    requests.removeFirst()
                    throw error
                }
                requests.removeFirst()
                if packet.statusCode == SFTPError.endOfFile {
                    sawEnd = true
                    abandonRequests()
                    continue
                }
                var decoder = try packet.expect(.data)
                let data = try decoder.bytes()
                guard data.count <= chunk.length else { throw NetworkError.unexpected("more data than asked for") }
                if data.isEmpty {
                    // An answer without data and without an end of file status: nothing more comes.
                    sawEnd = true
                    abandonRequests()
                    continue
                }
                window.moved(data.count)
                leftover = data
                if !chunk.isRest, chunk.length == block {
                    if data.count == chunk.length {
                        (shortAnswer, shortAnswers) = (nil, 0)
                    } else if data.count == shortAnswer {
                        shortAnswers += 1
                        // Every answer stops at the same length: more is not asked for from now
                        // on, which spares a second request for the rest of every piece.
                        if shortAnswers >= 3 { block = max(512, data.count) }
                    } else {
                        (shortAnswer, shortAnswers) = (data.count, 1)
                    }
                }
                if data.count < chunk.length {
                    // A short answer leaves a gap before the requests behind it; the rest of
                    // this piece is asked for first.
                    let rest = try sendRequest(
                        at: chunk.offset + UInt64(data.count),
                        length: chunk.length - data.count,
                        isRest: true,
                        handle
                    )
                    requests.insert(rest, at: 0)
                }
                // Kept full while the caller still waits for more.
                try fill(want(count - result.count), handle)
            }
            // The next requests are on their way before the caller has handled this piece.
            if !sawEnd, ahead > 0 { try fill(min(ahead, window.limit(block: block)), handle) }
        } catch {
            guard !result.isEmpty else {
                rewind(to: position)
                throw error
            }
            // What was read is delivered; the failure shows again when the read is repeated.
            rewind(to: position)
        }
        return result.isEmpty ? nil : result
    }

    func seek(to offset: UInt64) throws {
        if abort.isCancelled { throw NetworkError.cancelled }
        if offset == position { return }
        if offset > position, offset - position <= UInt64(leftover.count) {
            leftover = leftover.dropFirst(Int(offset - position))
            position = offset
            return
        }
        rewind(to: offset)
        // A jump: what follows may be one small read, so nothing is read ahead until it reads on.
        depth = Self.firstDepth
        readsInARow = 0
    }

    func close() {
        guard let handle else { return }
        self.handle = nil
        abandonRequests()
        session.closeHandle(handle, on: channel)
    }

    func interrupt() { abort.cancel() }
}

/// A file being written over SFTP. The write requests are not waited for one by one: up to a
/// window of them are under way, and their answers are collected as they arrive, in the next
/// call or at the latest when the file is closed. A refusal is therefore reported by a later
/// `write` or by `close`.
///
/// Requests that follow a refused one are already on their way and may well be carried out, which
/// would leave a file with a gap of nothing in it. On the first failure the file is therefore
/// cut back to the first byte that was not confirmed: what is left on the server is a true
/// start of the file, and continuing it later is safe. `close` reports success only when every
/// write was confirmed, the server's length is the length written, and the server confirmed
/// the closing itself (which is where a full disk or a quota shows on some servers).
/// Used by one thread at a time, as `FileWriter` allows; `interrupt` only sets the flag, which is
/// safe from any thread.
private final class SFTPFileWriter: FileWriter, @unchecked Sendable {
    /// One write request that is not confirmed yet.
    private struct Piece {
        let ticket: SFTPChannel.Ticket
        let offset: UInt64
        let length: Int
    }

    private let session: SFTPSession
    private let channel: SFTPChannel
    private var handle: Data?
    private var position: UInt64 = 0
    /// The requests whose answers are still to come, oldest first.
    private var outstanding: [Piece] = []
    private var failure: any Error?
    private var window = TransferWindow()
    private var depth = 4
    /// Set by `interrupt`; see `SFTPFileReader`.
    private let abort = CancellationFlag()

    init(session: SFTPSession, channel: SFTPChannel, handle: Data, position: UInt64 = 0) {
        self.session = session
        self.channel = channel
        self.handle = handle
        self.position = position
    }

    deinit {
        // Dropped without `close`: like a failure, and the handle is closed, which never waits.
        guard let handle else { return }
        if failure == nil {
            fail(NetworkError.cancelled, firstUnconfirmed: outstanding.first?.offset ?? position, handle: handle)
        }
        session.closeHandle(handle, on: channel)
    }

    /// Records the first failure, gives up the requests under way, and has the server cut the
    /// file back to `firstUnconfirmed`. The cut is put in line behind the writes that are under
    /// way and is not waited for: the server may not be answering.
    private func fail(_ error: any Error, firstUnconfirmed: UInt64, handle: Data) {
        guard failure == nil else { return }
        failure = error
        outstanding.forEach { channel.abandon($0.ticket) }
        outstanding = []
        var cut = SFTPAttributes()
        cut.size = firstUnconfirmed
        channel.sendWithoutAnswer(.fsetstat) {
            $0.bytes(handle)
            $0.attributes(cut)
        }
    }

    /// Takes the answers that have arrived, and waits for the oldest while more than `keep`
    /// are outstanding. The first failure is kept and thrown from then on.
    private func collect(keeping keep: Int, handle: Data) throws {
        if abort.isCancelled {
            fail(NetworkError.cancelled, firstUnconfirmed: outstanding.first?.offset ?? position, handle: handle)
        }
        if let failure { throw failure }
        while let oldest = outstanding.first {
            do {
                let packet: SFTPPacket
                if let arrived = channel.poll(oldest.ticket) {
                    packet = arrived
                } else if outstanding.count > keep {
                    packet = try channel.wait(for: oldest.ticket, timeout: session.timeout, cancellation: abort)
                } else {
                    return
                }
                try packet.checkStatus()
                outstanding.removeFirst()
                window.moved(oldest.length)
            } catch {
                fail(error, firstUnconfirmed: oldest.offset, handle: handle)
                throw error
            }
        }
    }

    func write(_ data: Data) throws {
        guard let handle else { throw NetworkError.connectionLost }
        let block = SFTPSession.blockSize
        depth = min(SFTPSession.window, depth * 2)
        var offset = 0
        while offset < data.count {
            try collect(keeping: min(depth, window.limit(block: block)) - 1, handle: handle)
            let end = min(offset + block, data.count)
            let piece = data[data.startIndex + offset..<data.startIndex + end]
            let start = position + UInt64(offset)
            do {
                let ticket = try channel.send(.write, cancellation: abort) {
                    $0.bytes(handle)
                    $0.u64(start)
                    $0.bytes(piece)
                }
                outstanding.append(Piece(ticket: ticket, offset: start, length: piece.count))
            } catch {
                fail(error, firstUnconfirmed: outstanding.first?.offset ?? start, handle: handle)
                throw error
            }
            offset = end
        }
        position += UInt64(data.count)
    }

    func close(attributes: FileAttributes) throws {
        guard let handle else { return }
        do {
            try collect(keeping: 0, handle: handle)
        } catch {
            // The cut is in line already; the handle follows it.
            self.handle = nil
            session.closeHandle(handle, on: channel)
            throw error
        }
        self.handle = nil
        var changes = SFTPAttributes()
        changes.modified = attributes.modified.map { UInt32(clamping: Int64($0.timeIntervalSince1970)) }
        changes.permissions = attributes.permissions.map { UInt32($0 & 0o7777) }
        // Date and permissions, the question for the length, and the closing go out together
        // and are answered in that order, so a small file costs one round trip, not three.
        var closing: SFTPChannel.Ticket?
        let courtesy: SFTPChannel.Ticket?
        let length: SFTPChannel.Ticket
        do {
            // Date and permissions are a courtesy; a server that refuses them still has the file.
            courtesy =
                changes.modified != nil || changes.permissions != nil
                ? try channel.send(.fsetstat, cancellation: abort) {
                    $0.bytes(handle)
                    $0.attributes(changes)
                } : nil
            length = try channel.send(.fstat, cancellation: abort) { $0.bytes(handle) }
            closing = try channel.send(.close, cancellation: abort) { $0.bytes(handle) }
        } catch {
            if closing == nil { session.closeHandle(handle, on: channel) }
            throw error
        }
        if let courtesy { _ = try? channel.wait(for: courtesy, timeout: session.timeout, cancellation: abort) }
        let measured = try? channel.wait(for: length, timeout: session.timeout, cancellation: abort)
        // The closing is the server's last word on the file: an error here is an error of the upload.
        if let closing { try channel.wait(for: closing, timeout: session.timeout, cancellation: abort).checkStatus() }
        if let measured, var found = try? measured.expect(.attributes), let size = try? found.attributes().size,
            size != position
        {
            throw NetworkError.unexpected("the file on the server has \(size) bytes after the upload, not \(position)")
        }
    }

    func interrupt() { abort.cancel() }
}

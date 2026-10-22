import AFMKernel
public import Foundation

/// The program that carries the SFTP dialogue instead of `/usr/bin/ssh`: tests run the
/// system's own `sftp-server` on a sandbox folder this way, without a network or a login.
public struct SFTPTransport: Sendable {
    public var executable: String
    public var arguments: [String]
    /// True when the program is an `ssh` that may have questions, which are then answered
    /// through `SSH_ASKPASS` like those of the real connection.
    public var asksQuestions: Bool

    public init(executable: String, arguments: [String] = [], asksQuestions: Bool = false) {
        self.executable = executable
        self.arguments = arguments
        self.asksQuestions = asksQuestions
    }
}

/// An error status of the SFTP server.
public struct SFTPError: LocalizedError, Sendable {
    public let code: UInt32
    public let message: String

    static let endOfFile: UInt32 = 1
    static let noSuchFile: UInt32 = 2

    public var errorDescription: String? {
        if !message.isEmpty, message != "Failure" {
            return "The server answered: \(message)"
        }
        switch code {
        case 2:
            return "The file or folder does not exist on the server."

        case 3:
            return "The server does not permit this."

        case 8:
            return "The server does not support this operation."

        default:
            return "The server reported an error (\(code))."
        }
    }
}

/// The attributes SFTP sends with a name (draft-ietf-secsh-filexfer-02 › File Attributes).
struct SFTPAttributes {
    var size: UInt64?
    var permissions: UInt32?
    var modified: UInt32?

    var isDirectory: Bool { (permissions ?? 0) & 0o170000 == 0o040000 }
    var isSymlink: Bool { (permissions ?? 0) & 0o170000 == 0o120000 }

    /// A device, a pipe or a socket.
    var isSpecial: Bool { [0o010000, 0o020000, 0o060000, 0o140000].contains((permissions ?? 0) & 0o170000) }

    func entry(named name: String) -> RemoteEntry {
        var entry = RemoteEntry(
            name: name,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            size: Int64(clamping: size ?? 0),
            modified: modified.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            permissions: permissions.map { UInt16($0 & 0o7777) }
        )
        entry.isSpecial = isSpecial
        return entry
    }
}

/// Builds the body of a packet: big-endian numbers and length-prefixed strings.
struct SFTPEncoder {
    private(set) var data = Data()
    /// The names of the server that are written back as they came (see `NameMemory`).
    var names: NameMemory?

    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }

    mutating func bytes(_ value: Data) {
        u32(UInt32(value.count))
        data.append(value)
    }

    /// Starts a packet: the length, filled in by `finishPacket`, the type and the request number.
    mutating func beginPacket(_ type: UInt8, id: UInt32? = nil) {
        u32(0)
        u8(type)
        if let id { u32(id) }
    }

    /// Writes the length at the front, now that the packet is complete.
    mutating func finishPacket() {
        let length = UInt32(data.count - 4).bigEndian
        withUnsafeBytes(of: length) { data.replaceSubrange(0..<4, with: $0) }
    }

    /// Names travel as composed UTF-8, which is what servers store, except the names the
    /// server itself spelled another way (decomposed, or not UTF-8 at all): those go back as
    /// the bytes they came as, or they would not name the same file.
    mutating func string(_ value: String) {
        guard let names, !names.isEmpty else {
            bytes(Data(value.precomposedStringWithCanonicalMapping.utf8))
            return
        }
        var result = Data()
        for (index, piece) in Array(value.utf8).split(separator: 0x2F, omittingEmptySubsequences: false).enumerated() {
            if index > 0 { result.append(0x2F) }
            let name = String(decoding: piece, as: UTF8.self)
            if let spelled = names.encoding(of: piece),
                let kept = name.data(using: spelled, allowLossyConversion: false)
            {
                result.append(kept)
            } else {
                result.append(Data(name.precomposedStringWithCanonicalMapping.utf8))
            }
        }
        bytes(result)
    }

    mutating func attributes(_ value: SFTPAttributes = SFTPAttributes()) {
        u32((value.size != nil ? 1 : 0) | (value.permissions != nil ? 4 : 0) | (value.modified != nil ? 8 : 0))
        if let size = value.size { u64(size) }
        if let permissions = value.permissions { u32(permissions) }
        if let modified = value.modified {
            // Access time and time of change go together; both get the same value.
            u32(modified)
            u32(modified)
        }
    }
}

/// Reads the body of a packet.
///
/// Everything comes from the server, so every step is checked.
struct SFTPDecoder {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    private mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, data.endIndex - offset >= count else {
            throw NetworkError.unexpected("a damaged SFTP packet")
        }
        defer { offset += count }
        return data[offset..<offset + count]
    }

    mutating func u8() throws -> UInt8 {
        let byte = try take(1)
        return byte[byte.startIndex]
    }
    mutating func u32() throws -> UInt32 { try take(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
    mutating func u64() throws -> UInt64 { try take(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
    mutating func bytes() throws -> Data { try take(Int(try u32())) }
    mutating func string() throws -> String { String(decoding: try bytes(), as: UTF8.self) }

    /// A file name, and the encoding that read it: UTF-8 where the bytes are UTF-8, else
    /// Latin 1, which reads any bytes and writes the same bytes back.
    ///
    /// Read as UTF-8 with replacement characters, such a name could never be sent to the server
    /// again.
    mutating func name() throws -> (text: String, encoding: String.Encoding) {
        let raw = Data(try bytes())
        if let text = String(data: raw, encoding: .utf8) {
            return (text, .utf8)
        }
        // Latin 1 is the first 256 code points, one byte each.
        var text = String.UnicodeScalarView()
        text.append(contentsOf: raw.map { Unicode.Scalar($0) })
        return (String(text), .isoLatin1)
    }
    var isAtEnd: Bool { offset >= data.endIndex }

    mutating func attributes() throws -> SFTPAttributes {
        let flags = try u32()
        var attributes = SFTPAttributes()
        if flags & 1 != 0 { attributes.size = try u64() }
        if flags & 2 != 0 { _ = try take(8) }
        if flags & 4 != 0 { attributes.permissions = try u32() }
        if flags & 8 != 0 {
            _ = try u32()
            attributes.modified = try u32()
        }
        if flags & 0x8000_0000 != 0 {
            for _ in 0..<(try u32()) { _ = (try bytes(), try bytes()) }
        }
        return attributes
    }
}

/// One answer of the server: its type and what follows the request number.
struct SFTPPacket {
    enum Kind: UInt8 {
        case version = 2
        case status = 101
        case handle = 102
        case data = 103
        case name = 104
        case attributes = 105
        case extendedReply = 201
        /// Not a packet: the channel closed before an answer came.
        case closed = 0
    }

    let kind: Kind
    let body: Data

    /// Throws unless the packet is the success status.
    func checkStatus() throws {
        if kind == .closed { throw NetworkError.connectionLost }
        guard kind == .status else { throw NetworkError.unexpected("SFTP packet \(kind.rawValue)") }
        var decoder = SFTPDecoder(body)
        let code = try decoder.u32()
        if code != 0 { throw SFTPError(code: code, message: (try? decoder.string()) ?? "") }
    }

    /// The status code when this is a status packet.
    var statusCode: UInt32? {
        guard kind == .status else {
            return nil
        }
        var decoder = SFTPDecoder(body)
        return try? decoder.u32()
    }

    /// The payload of an answer of the expected kind, which is never a status: an error status
    /// is thrown, and so is a success where something else was expected.
    func expect(_ wanted: Kind) throws -> SFTPDecoder {
        if kind == .closed { throw NetworkError.connectionLost }
        if kind == .status { try checkStatus() }
        guard kind == wanted else { throw NetworkError.unexpected("SFTP packet \(kind.rawValue)") }
        return SFTPDecoder(body)
    }
}

/// The request types of SFTP version 3.
enum SFTPRequest: UInt8 {
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case lstat = 7
    case fstat = 8
    case setstat = 9
    case fsetstat = 10
    case opendir = 11
    case readdir = 12
    case remove = 13
    case mkdir = 14
    case rmdir = 15
    case realpath = 16
    case stat = 17
    case rename = 18
    case extended = 200
}

/// Lets `ssh` ask its questions (a password, the passphrase of a key, an unknown host key)
/// through this program instead of a terminal: `SSH_ASKPASS` points to a tiny script that
/// writes the question into one named pipe and reads the answer from another.
///
/// Nothing secret is ever put into the environment, on the command line or into a file. Used by one
/// thread.
///
/// Every run of the script gives its question a number of its own and takes only the answer
/// that carries it: an answer that was written for a script which ssh had ended meanwhile
/// stays in the pipe, and must not answer the next question.
final class AskpassHelper {
    /// What ssh wants from the helper (`SSH_ASKPASS_PROMPT`).
    enum Kind: Equatable {
        /// A text to be typed: a password, a passphrase, or `yes` to a host key.
        case entry
        /// Yes or no (the touch of a security key to be allowed).
        case confirm
        /// Nothing to answer: a notice (touch the security key now).
        case notice
    }

    struct Question: Equatable {
        let id: String
        let kind: Kind
        let text: String
    }

    let directory: URL
    private let question: Int32
    private let answer: Int32
    private let endMarker = "END-" + UUID().uuidString
    private var received = Data()
    /// More than this is not collected while a question has no end.
    private static let longestQuestion = 64 * 1_024

    /// The pipes and the script go into a new folder in `parent`, the temporary folder of the user
    /// unless said otherwise.
    init(in parent: URL = FileManager.default.temporaryDirectory) throws {
        directory = parent.appendingPathComponent("afm-askpass-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let (questionPath, answerPath) = (
            directory.appendingPathComponent("question").path, directory.appendingPathComponent("answer").path
        )
        guard mkfifo(questionPath, 0o600) == 0, mkfifo(answerPath, 0o600) == 0 else {
            // Nothing is left behind of a helper that could not be made.
            try? FileManager.default.removeItem(at: directory)
            throw POSIXError(.EIO)
        }
        // Opened for reading and writing, so neither end blocks or sees an end of file while
        // the script comes and goes.
        question = open(questionPath, O_RDWR | O_NONBLOCK)
        answer = open(answerPath, O_RDWR | O_NONBLOCK)
        let script = """
            #!/bin/sh
            id="$$.$(date +%s)"
            kind="${SSH_ASKPASS_PROMPT:-}"
            printf '%s\\n%s\\n%s\\n%s\\n' "$id" "$kind" "$1" "$AFM_ASKPASS_END" > "$AFM_ASKPASS_QUESTION"
            exec 3< "$AFM_ASKPASS_ANSWER"
            reply=
            while IFS= read -r line <&3; do
              case "$line" in
                "$id "*) reply=${line#"$id "}; break ;;
              esac
            done
            if [ "$kind" = confirm ]; then
              [ "$reply" = yes ] && exit 0
              exit 1
            fi
            printf '%s\\n' "$reply"

            """
        let scriptURL = directory.appendingPathComponent("askpass.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
    }

    deinit {
        close(question)
        close(answer)
        try? FileManager.default.removeItem(at: directory)
    }

    /// What the child process needs in its environment.
    var environment: [String: String] {
        [
            "SSH_ASKPASS": directory.appendingPathComponent("askpass.sh").path, "SSH_ASKPASS_REQUIRE": "force",
            "AFM_ASKPASS_QUESTION": directory.appendingPathComponent("question").path,
            "AFM_ASKPASS_ANSWER": directory.appendingPathComponent("answer").path, "AFM_ASKPASS_END": endMarker
        ]
    }

    /// A question that has arrived completely; nil when there is none.
    func pendingQuestion() -> Question? {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(question, &buffer, buffer.count)
            guard count > 0 else { break }
            received.append(buffer, count: count)
            if received.count > Self.longestQuestion {
                received.removeFirst(received.count - Self.longestQuestion)
            }
        }
        let text = String(decoding: received, as: UTF8.self)
        guard let end = text.range(of: "\n" + endMarker + "\n") else {
            return nil
        }
        received = Data(text[end.upperBound...].utf8)
        // The number, what ssh wants, and the question, which may have lines of its own.
        let parts = text[..<end.lowerBound].split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            return nil
        }
        let kind: Kind = parts[1] == "confirm" ? .confirm : parts[1] == "none" ? .notice : .entry
        return Question(id: String(parts[0]), kind: kind, text: String(parts[2]))
    }

    /// Answers `question`, and no other.
    func reply(_ text: String, to question: Question) {
        // One line; a line break inside would be read as the end of the answer.
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let line = Data((question.id + " " + first).utf8) + Data([0x0A])
        _ = line.withUnsafeBytes { write(answer, $0.baseAddress, $0.count) }
    }
}

/// An SFTP dialogue over the standard input and output of a child process, normally
/// `ssh -s host sftp`: ssh does the encryption and the login, this class speaks the file
/// protocol (SFTP version 3, with OpenSSH's `posix-rename`).
///
/// **Threading.** Requests carry numbers and the answers name them, so any number of threads
/// may have requests under way at once: each sends under `writeLock` and waits for its own
/// answer, which the reading thread hands over. No pool of connections is needed.
///
/// The state, `extensions` included, is guarded by `lock` (the error text also by `errorReading`);
/// `writeTimeout` and `names` do not change after `init`.
final class SFTPChannel: @unchecked Sendable {
    private let process = Process()
    private let toServer = Pipe()
    private let fromServer = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    /// Held while a packet is written, and while the write end of the pipe is closed.
    private let writeLock = NSLock()
    /// How long writing a packet may make no progress before the channel is given up: ssh
    /// that does not read its input is stuck, and everything waiting behind it with it.
    let writeTimeout: TimeInterval
    private var waiting: [UInt32: Pending<SFTPPacket>] = [:]
    private var nextID: UInt32 = 1
    private var closed = false
    /// Requests nobody waits for (a handle to be closed), complete packets in order.
    ///
    /// They go out before the next packet anyone writes, so the server sees them in the order they
    /// were asked for, and the thread that asked does not wait for the pipe.
    private var deferred: [Data] = []
    /// When the server was last heard from.
    private var lastReceived = Date()
    /// The names of the server that are written back as they came.
    let names: NameMemory?
    private var errorText = Data()
    /// Held while a piece of the error output is read and kept (see `start`).
    private let errorReading = NSLock()
    /// Signalled by the reading thread when the stream has ended and the last words are read.
    private let lastWords = DispatchSemaphore(value: 0)
    private let version = Pending<SFTPPacket>()
    private var serverExtensions: [String: String] = [:]

    init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        writeTimeout: TimeInterval = 60,
        names: NameMemory? = nil
    ) {
        self.writeTimeout = writeTimeout
        self.names = names
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = toServer
        process.standardOutput = fromServer
        process.standardError = errors
    }

    deinit { close() }

    /// The extensions the server named in its first answer; known once `start` has returned.
    var extensions: [String: String] { lock.withLock { serverExtensions } }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// What the child process wrote to its error output, e.g. why the login failed.
    var errorMessage: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: errorText, as: UTF8.self).split(whereSeparator: \.isNewline).suffix(3)
            .joined(
                separator: "\n"
            )
    }

    /// `errorMessage` once the child process has had its say: when the dialogue broke off, the
    /// reading thread first reads what the process still wrote, and this waits for that, for a
    /// moment at most.
    ///
    /// For the thread that found the connection lost and wants to say why.
    func errorMessageAtTheEnd() -> String {
        // The reading thread comes to the end once the process has gone; on a busy machine that
        // can take a moment longer than the process itself, so it is given a few seconds.
        if lastWords.wait(timeout: .now() + Self.lastWordsTime + Self.endTime) == .success {
            lastWords.signal()
        }
        return errorMessage
    }

    /// Starts the process and the protocol. `service` is called a few times a second while the
    /// login is under way, to answer ssh's questions; it returns false to give up.
    func start(timeout: TimeInterval, cancellation: CancellationFlag?, service: () -> Bool) throws {
        errors.fileHandleForReading.readabilityHandler = { [weak self, errorReading] handle in
            // Reading and keeping are one step under `errorReading`: whoever reads the rest at
            // the end (`drainErrors`) must not find the pipe empty while a piece that was
            // taken out of it here is not kept yet.
            errorReading.lock()
            defer { errorReading.unlock() }
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                return handle.readabilityHandler = nil
            }
            lock.lock()
            errorText.append(data)
            if errorText.count > 8_192 { errorText = Data(errorText.suffix(4_096)) }
            lock.unlock()
        }
        // The channel may be closed from another thread (a disconnect) at any moment, also
        // before the process runs. The process is started with `lock` held, so `close`, which
        // marks the channel closed first, either comes before (and nothing is started) or finds
        // the process running and ends it; the write end of the pipe is only closed after that.
        try lock.withLock {
            guard !closed else { throw NetworkError.connectionLost }
            // A write into a pipe whose reader died must fail, not kill this program. It must not
            // block either: a packet that cannot be written is waited for with a time limit.
            let input = toServer.fileHandleForWriting.fileDescriptor
            _ = fcntl(input, F_SETNOSIGPIPE, 1)
            _ = fcntl(input, F_SETFL, fcntl(input, F_GETFL) | O_NONBLOCK)
            do {
                try process.run()
            } catch {
                throw NetworkError.connectionFailed(error.localizedDescription)
            }
        }
        // The thread holds the reading end of the pipe, which stays open until it is done,
        // whatever happens to the channel.
        let output = fromServer.fileHandleForReading
        let lastWords = lastWords
        let reader = Thread { [weak self] in
            Self.readPackets(from: output) { self?.received($0) ?? false }
            // The stream ended, or what came was not SFTP: the dialogue is over, and ssh with it.
            // What ssh said last (why the login failed) is read before anyone is told: its two
            // outputs end together, and the end of one may be seen before the text of the other.
            self?.drainErrors()
            self?.close()
            lastWords.signal()
        }
        reader.name = "afm.network.sftp"
        reader.start()

        var hello = SFTPEncoder()
        hello.beginPacket(1)
        hello.u32(3)
        hello.finishPacket()
        try write(hello.data)
        var deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let packet = try version.wait(timeout: 0.1, cancellation: cancellation) {
                var decoder = try packet.expect(.version)
                _ = try decoder.u32()
                var named: [String: String] = [:]
                while !decoder.isAtEnd, let name = try? decoder.string(), let value = try? decoder.string() {
                    named[name] = value
                }
                lock.withLock { serverExtensions = named }
                return
            }
            let asked = Date()
            guard service() else { throw NetworkError.cancelled }
            // The time the user took to answer does not count.
            deadline.addTimeInterval(Date().timeIntervalSince(asked))
        } while Date() <= deadline
        throw NetworkError.timedOut("logging in")
    }

    /// Reads what the child process still has to say on its error output, for a moment at most
    /// (a process ssh started may hold the pipe open for longer).
    ///
    /// Runs on the reading thread, once, when the dialogue has ended.
    private func drainErrors() {
        let handle = errors.fileHandleForReading
        handle.readabilityHandler = nil
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let deadline = Date().addingTimeInterval(Self.lastWordsTime)
        var buffer = [UInt8](repeating: 0, count: 4_096)
        errorReading.lock()
        defer { errorReading.unlock() }
        while Date() < deadline {
            var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&waiting, 1, 50) > 0 else { continue }
            // Nobody else reads the pipe now (the handler above is gone, and `errorReading` is
            // held), so a descriptor that is ready has bytes or its end: a read that does not
            // block is not interrupted, and finds what `poll` saw.
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else {
                return
            }
            lock.lock()
            errorText.append(buffer, count: count)
            if errorText.count > 8_192 { errorText = Data(errorText.suffix(4_096)) }
            lock.unlock()
        }
    }

    /// How long the last words of the child process are waited for after its output ended.
    static let lastWordsTime: TimeInterval = 2
    /// How long the thread that found the connection lost waits for the reading thread to see the end.
    static let endTime: TimeInterval = 8

    /// Reads packets until the stream ends or `handle` returns false.
    ///
    /// Runs on the reading thread.
    private static func readPackets(from input: FileHandle, handle: (SFTPPacket) -> Bool) {
        // `FileHandle` reads again when a signal interrupts it; a failure is the end of the stream.
        func readExactly(_ count: Int) -> Data? {
            var data = Data()
            while data.count < count {
                guard let piece = try? input.read(upToCount: count - data.count), !piece.isEmpty else {
                    return nil
                }
                data.append(piece)
            }
            return data
        }
        while let header = readExactly(4) {
            let length = Int(header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            // Nothing the protocol sends is this large (a read brings 32 KB, OpenSSH never sends more
            // than 256 KB); a wrong length means the stream is not SFTP, and is not made room for.
            guard length >= 1, length <= Self.largestPacket, let payload = readExactly(length),
                let kind = SFTPPacket.Kind(rawValue: payload[0])
            else { return }
            // The body is a view of the payload; nothing is copied.
            if !handle(SFTPPacket(kind: kind, body: payload.dropFirst())) {
                return
            }
        }
    }

    static let largestPacket = 1 << 20

    private func received(_ packet: SFTPPacket) -> Bool {
        if packet.kind == .version {
            version.fulfill(packet)
            return true
        }
        var decoder = SFTPDecoder(packet.body)
        guard let id = try? decoder.u32() else {
            return false
        }
        lock.lock()
        lastReceived = Date()
        let waiter = waiting.removeValue(forKey: id)
        lock.unlock()
        waiter?.fulfill(SFTPPacket(kind: packet.kind, body: packet.body.dropFirst(4)))
        return true
    }

    private func markClosed() {
        lock.lock()
        closed = true
        let all = waiting.values
        waiting = [:]
        deferred = []
        lock.unlock()
        let end = SFTPPacket(kind: .closed, body: Data())
        version.fulfill(end)
        all.forEach { $0.fulfill(end) }
    }

    /// Takes the right to write, waiting in short turns so that a cancellation is noticed.
    private func lockForWriting(cancellation: CancellationFlag?) throws {
        let deadline = Date().addingTimeInterval(writeTimeout)
        while !writeLock.lock(before: min(deadline, Date().addingTimeInterval(0.1))) {
            if cancellation?.isCancelled == true { throw NetworkError.cancelled }
            if Date() >= deadline { throw NetworkError.timedOut("sending to the server") }
        }
    }

    /// How long a writer that was cancelled in the middle of a packet goes on while the pipe
    /// takes nothing at all.
    private static let cancelGrace: TimeInterval = 2

    /// Writes all of `packet` into the pipe.
    ///
    /// The pipe does not block: when it is full the writer waits for room, up to `writeTimeout`
    /// without progress. A cancellation is obeyed at once before the first byte. After it, the
    /// packet is finished for as long as the pipe keeps taking bytes: the channel is shared, a
    /// packet left half written would end the dialogue for every transfer, and a packet is small (a
    /// block of a file at most), so on a slow line, where the pipe is always full but always
    /// moving, cancelling one upload costs the others nothing. Only when the pipe takes nothing for
    /// `cancelGrace` is the cancelled writer let go, and the channel with it: that line is not
    /// moving for anybody.
    ///
    /// `descriptor` does not block (a write that does not block is not interrupted by a signal);
    /// `isClosed` says whether the channel was closed meanwhile.
    static func writeAll(
        _ packet: Data,
        to descriptor: Int32,
        writeTimeout: TimeInterval,
        cancellation: CancellationFlag?,
        isClosed: () -> Bool
    ) throws {
        try packet.withUnsafeBytes { buffer in
            var sent = 0
            var moved = Date()
            while sent < buffer.count {
                // A channel that was closed meanwhile sends nothing more, also while the pipe takes it.
                guard !isClosed() else { throw NetworkError.connectionLost }
                let count = Darwin.write(descriptor, buffer.baseAddress! + sent, buffer.count - sent)
                if count > 0 {
                    sent += count
                    moved = Date()
                    continue
                }
                guard count < 0, errno == EAGAIN else { throw NetworkError.connectionLost }
                let stuck = Date().timeIntervalSince(moved)
                if stuck >= writeTimeout { throw NetworkError.timedOut("sending to the server") }
                if cancellation?.isCancelled == true {
                    if sent == 0 { throw NetworkError.cancelled }
                    if stuck >= cancelGrace { throw NetworkError.connectionLost }
                }
                var wanted = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                _ = Darwin.poll(&wanted, 1, 200)
            }
        }
    }

    private func writeAll(_ packet: Data, to descriptor: Int32, cancellation: CancellationFlag?) throws {
        try Self.writeAll(
            packet,
            to: descriptor,
            writeTimeout: writeTimeout,
            cancellation: cancellation,
            isClosed: { isClosed }
        )
    }

    /// Writes one complete packet, after the packets that were put aside for it
    /// (`sendWithoutAnswer`).
    ///
    /// Any failure in the middle of a packet leaves the dialogue unusable and ends the channel; a
    /// cancellation that comes before the first byte does not.
    private func write(_ packet: Data?, cancellation: CancellationFlag? = nil) throws {
        do {
            try lockForWriting(cancellation: cancellation)
            defer { writeLock.unlock() }
            while true {
                lock.lock()
                let isOver = closed
                let queued = deferred
                deferred = []
                lock.unlock()
                // The pipe is only closed with `writeLock` held and the channel marked closed,
                // so past this check its descriptor is good for as long as the lock is held.
                guard !isOver else { throw NetworkError.connectionLost }
                if queued.isEmpty { break }
                // These are owed to the server whatever becomes of the caller.
                let descriptor = toServer.fileHandleForWriting.fileDescriptor
                for packet in queued { try writeAll(packet, to: descriptor, cancellation: nil) }
            }
            if let packet {
                try writeAll(packet, to: toServer.fileHandleForWriting.fileDescriptor, cancellation: cancellation)
            }
        } catch NetworkError.cancelled {
            throw NetworkError.cancelled
        } catch {
            close()
            throw error
        }
    }

    /// Sends a request whose answer nobody needs (closing a handle that was only read, or one of
    /// a transfer that was given up).
    ///
    /// Returns at once, from any thread: the packet is put in line and written before the next
    /// request, by whoever writes next or, when nobody does, in the background. The server
    /// therefore sees it before anything that is asked afterwards (the removal of a file whose
    /// handle is closed here).
    func sendWithoutAnswer(_ type: SFTPRequest, _ build: (inout SFTPEncoder) -> Void) {
        var packet = SFTPEncoder()
        packet.names = names
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        let id = nextID
        nextID &+= 1
        packet.beginPacket(type.rawValue, id: id)
        build(&packet)
        packet.finishPacket()
        deferred.append(packet.data)
        lock.unlock()
        Background.run(lane: self) { [weak self] in try? self?.write(nil) }
    }

    /// A request that was sent, to be waited for or given up.
    struct Ticket {
        let id: UInt32
        let answer: Pending<SFTPPacket>
    }

    /// Sends a request without waiting; several can be under way and are answered in any order.
    func send(_ type: SFTPRequest, cancellation: CancellationFlag? = nil, _ build: (inout SFTPEncoder) -> Void) throws
        -> Ticket
    {
        if cancellation?.isCancelled == true { throw NetworkError.cancelled }
        let answer = Pending<SFTPPacket>()
        // A closed channel is found out by `write`, which looks under the lock it writes with.
        lock.lock()
        let id = nextID
        nextID &+= 1
        waiting[id] = answer
        lock.unlock()
        var packet = SFTPEncoder()
        packet.names = names
        packet.beginPacket(type.rawValue, id: id)
        build(&packet)
        packet.finishPacket()
        do {
            try write(packet.data, cancellation: cancellation)
        } catch {
            lock.lock()
            waiting[id] = nil
            lock.unlock()
            throw error
        }
        return Ticket(id: id, answer: answer)
    }

    /// The answer when it has arrived; never waits.
    func poll(_ ticket: Ticket) -> SFTPPacket? { ticket.answer.poll() }

    /// Stops expecting the answer of a request.
    ///
    /// If it still comes it is dropped.
    func abandon(_ ticket: Ticket) {
        lock.lock()
        waiting[ticket.id] = nil
        lock.unlock()
    }

    /// Waits for one answer.
    ///
    /// When it takes too long only this request is given up: the answers are matched by number, so
    /// the others are not affected, and a server that is merely slow with one request does not lose
    /// every transfer that is running. But when nothing at all arrived from the server in that
    /// time, the connection is taken for dead and the channel is closed: every later request would
    /// otherwise wait out its own time limit on it, one after the other. The next request opens a
    /// new channel.
    func wait(for ticket: Ticket, timeout: TimeInterval, cancellation: CancellationFlag? = nil) throws -> SFTPPacket {
        let began = Date()
        let packet: SFTPPacket?
        do {
            packet = try ticket.answer.wait(timeout: timeout, cancellation: cancellation)
        } catch {
            abandon(ticket)
            throw error
        }
        guard let packet else {
            abandon(ticket)
            lock.lock()
            let isSilent = lastReceived < began
            lock.unlock()
            if isSilent { close() }
            throw NetworkError.timedOut("waiting for the server")
        }
        if packet.kind == .closed { throw NetworkError.connectionLost }
        return packet
    }

    func request(
        _ type: SFTPRequest,
        timeout: TimeInterval,
        cancellation: CancellationFlag? = nil,
        _ build: (inout SFTPEncoder) -> Void
    ) throws -> SFTPPacket {
        let ticket = try send(type, cancellation: cancellation, build)
        do {
            return try wait(for: ticket, timeout: timeout, cancellation: cancellation)
        } catch {
            abandon(ticket)
            throw error
        }
    }

    /// Ends the dialogue and the child process.
    ///
    /// Returns at once, from any thread.
    func close() {
        errors.fileHandleForReading.readabilityHandler = nil
        // Marked closed first: a `start` under way then either starts nothing, or has started
        // the process by now (it holds `lock` meanwhile), which is ended here.
        markClosed()
        if process.isRunning { process.terminate() }
        // The write end goes when no writer is using it. A writer finds the channel closed
        // before its next write into the pipe, or after a wait of a fifth of a second for room
        // in it; until then the pipe is closed in the background, so this thread (possibly the
        // main thread) does not wait for it.
        let (gate, input) = (writeLock, toServer.fileHandleForWriting)
        if gate.try() {
            try? input.close()
            gate.unlock()
        } else {
            Background.run(lane: gate) {
                gate.lock()
                try? input.close()
                gate.unlock()
            }
        }
    }
}

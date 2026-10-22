import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// An SFTP server written for these tests, run by the Python that comes with the developer
/// tools.
///
/// Unlike the system's `sftp-server` it can be made to behave badly: every answer comes after a
/// random delay (so answers arrive out of order), reads are cut short, reads fail from some
/// position on, a request is never answered, or nothing is read from the pipe at all. Unchecked:
/// set up in `init` and not changed afterwards.
final class FakeSFTPServer: @unchecked Sendable {
    static let python = "/usr/bin/python3"
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: python) }

    enum Mode: String {
        case normal
        /// Reads at or behind 98304 answer with a failure.
        case failingReads = "failread"
        /// A stat of a path ending in `hang` is never answered.
        case hangingStat = "hang"
        /// Answers the first packet and then reads no more.
        case stalled = "stall"
        /// Opening a directory, reads from 98304 on and every write are never answered, nor is a stat of `hang`.
        case hangingIO = "hangio"
        /// Closing a handle that was written to answers with a failure (a full disk that shows at the end).
        case failingClose = "failclose"
        /// The write at 65536 is refused; the writes before and after it are carried out.
        case failingWrite = "failwrite"
        /// Every write is confirmed, but nothing behind 65536 is stored.
        case forgetfulWrite = "forgetwrite"
        /// A plain rename onto an existing name is refused, and so is every rename of a name ending in `locked`.
        case strictRename = "strictrename"
        /// Where a link leads (a stat that follows it) is never told for a name ending in `hang`, refused for one
        /// ending in `deny`, and asking about one ending in `die` ends the server.
        case links
        /// Reading a directory closes the server's input before the answer: what the client sends next finds
        /// nobody reading.
        case cutListing = "cutlisting"
        /// The length of an open file is not told.
        case noSize = "nosize"
        /// A read is answered with more bytes than were asked for.
        case overlong
        /// A read is answered with no bytes and no end of file.
        case emptyData = "emptydata"
        /// No read is answered with more than 1,000 bytes; the length of every read asked for goes to
        /// `sftp-reads.log`.
        case shortReads = "shortreads"
        /// The answer to the first question after the greeting is too short to name its request.
        case shortPacket = "shortpacket"
    }

    let transport: SFTPTransport

    init(root: URL, box: Sandbox, mode: Mode = .normal, delay: ClosedRange<Int> = 20...60) throws {
        let script = box.url("fake-sftp.py")
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        transport = SFTPTransport(
            executable: Self.python,
            arguments: [script.path, mode.rawValue, root.path, String(delay.lowerBound), String(delay.upperBound)]
        )
    }

    static let script = """
        import heapq, os, random, select, struct, sys, time
        mode, root, low, high = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
        handles = {}
        folders = {}
        written = set()
        nextHandle = [1]
        log = open(os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), "sftp-requests.log"), "a")
        due = []
        counter = [0]
        peak = [0]
        peakPath = os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), "sftp-peak.log")
        buffer = b""

        def u32(value): return struct.pack(">I", value)
        def string(value):
            if isinstance(value, str): value = value.encode()
            return u32(len(value)) + value
        def packet(kind, body): return u32(len(body) + 1) + bytes([kind]) + body
        def status(ident, code, message=""): return packet(101, u32(ident) + u32(code) + string(message) + string(""))
        def attributes(path, follow=False):
            info = os.stat(path) if follow else os.lstat(path)
            return u32(1 | 4 | 8) + struct.pack(">Q", info.st_size) + u32(info.st_mode) + u32(int(info.st_atime)) + u32(int(info.st_mtime))

        def send_later(data):
            delay = random.uniform(low, high) / 1000.0
            counter[0] += 1
            heapq.heappush(due, (time.time() + delay, counter[0], data))
            # The most answers that were owed at one moment: what a test reads to see requests overlap.
            if len(due) > peak[0]:
                peak[0] = len(due)
                with open(peakPath, "w") as out: out.write(str(peak[0]))

        def take_string(data, at):
            (length,) = struct.unpack_from(">I", data, at)
            return data[at + 4:at + 4 + length], at + 4 + length

        def handle(kind, body):
            if kind == 1:
                os.write(1, packet(2, u32(3)))
                if mode == "stall":
                    time.sleep(600)
                return
            (ident,) = struct.unpack_from(">I", body, 0)
            at = 4
            log.write(str(kind) + "\\n")
            log.flush()
            if kind == 16:
                name, at = take_string(body, at)
                if mode == "shortpacket":
                    os.write(1, packet(101, b"\\0\\0"))
                    return
                send_later(packet(104, u32(ident) + u32(1) + string("/") + string("/") + u32(0)))
            elif kind in (7, 17):
                name, at = take_string(body, at)
                path = os.path.join(root, name.decode().lstrip("/"))
                if name.decode().endswith("hang") and mode in ("hang", "hangio"):
                    return
                if kind == 17 and mode == "links":
                    if name.decode().endswith("hang"):
                        return
                    if name.decode().endswith("die"):
                        os._exit(0)
                    if name.decode().endswith("deny"):
                        send_later(status(ident, 3, "Permission denied"))
                        return
                try:
                    send_later(packet(105, u32(ident) + attributes(path, follow=kind == 17)))
                except OSError:
                    send_later(status(ident, 2, "No such file"))
            elif kind == 11:
                name, at = take_string(body, at)
                if mode == "hangio":
                    return
                if not os.path.isdir(os.path.join(root, name.decode().lstrip("/"))):
                    send_later(status(ident, 2, "No such file"))
                    return
                number = nextHandle[0]
                nextHandle[0] += 1
                folders[number] = os.path.join(root, name.decode().lstrip("/"))
                send_later(packet(102, u32(ident) + string(str(number))))
            elif kind == 12:
                name, at = take_string(body, at)
                folder = folders.get(int(name))
                if folder is None:
                    send_later(status(ident, 1, "EOF"))
                    return
                folders[int(name)] = None
                names = sorted(os.listdir(folder))
                answer = u32(ident) + u32(len(names))
                for entry in names:
                    answer += string(entry) + string(entry) + attributes(os.path.join(folder, entry))
                if mode == "cutlisting":
                    os.close(0)
                    os.write(1, packet(104, answer))
                    time.sleep(600)
                send_later(packet(104, answer))
            elif kind == 3:
                name, at = take_string(body, at)
                (flags,) = struct.unpack_from(">I", body, at)
                path = os.path.join(root, name.decode().lstrip("/"))
                try:
                    if flags & 2:
                        creating = (os.O_CREAT if flags & 8 else 0) | (os.O_EXCL if flags & 32 else 0)
                        descriptor = os.open(path, os.O_WRONLY | creating, 0o644)
                    else:
                        descriptor = os.open(path, os.O_RDONLY)
                except OSError as error:
                    send_later(status(ident, 2 if error.errno == 2 else 4, str(error)))
                    return
                number = nextHandle[0]
                nextHandle[0] += 1
                handles[number] = descriptor
                send_later(packet(102, u32(ident) + string(str(number))))
            elif kind == 5:
                name, at = take_string(body, at)
                offset, length = struct.unpack_from(">QI", body, at)
                descriptor = handles[int(name)]
                if mode == "hangio" and offset >= 98304:
                    return
                if mode == "failread" and offset >= 98304:
                    send_later(status(ident, 4, "Read failed"))
                    return
                if mode == "shortreads":
                    with open(os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), "sftp-reads.log"), "a") as out:
                        out.write(str(length) + "\\n")
                    length = min(length, 1000)
                elif mode == "emptydata":
                    send_later(packet(103, u32(ident) + string(b"")))
                    return
                elif mode == "overlong":
                    send_later(packet(103, u32(ident) + string(b"x" * (length + 10))))
                    return
                elif random.random() < 0.3:
                    # Some answers are shorter than asked for.
                    length = random.randint(1, length)
                data = os.pread(descriptor, length, offset)
                if not data:
                    send_later(status(ident, 1, "EOF"))
                else:
                    send_later(packet(103, u32(ident) + string(data)))
            elif kind == 6:
                name, at = take_string(body, at)
                (offset,) = struct.unpack_from(">Q", body, at)
                data, at = take_string(body, at + 8)
                if mode == "hangio":
                    return
                descriptor = handles[int(name)]
                written.add(int(name))
                if mode == "failwrite" and offset == 65536:
                    send_later(status(ident, 4, "No space left on device"))
                    return
                if not (mode == "forgetwrite" and offset >= 65536):
                    os.pwrite(descriptor, data, offset)
                send_later(status(ident, 0))
            elif kind == 4:
                name, at = take_string(body, at)
                descriptor = handles.pop(int(name), None)
                folders.pop(int(name), None)
                if descriptor is not None:
                    os.close(descriptor)
                if mode == "failclose" and int(name) in written:
                    send_later(status(ident, 4, "Disk quota exceeded"))
                else:
                    send_later(status(ident, 0))
            elif kind == 8:
                name, at = take_string(body, at)
                info = os.fstat(handles[int(name)])
                if mode == "nosize":
                    send_later(packet(105, u32(ident) + u32(4) + u32(info.st_mode)))
                    return
                send_later(packet(105, u32(ident) + u32(1 | 4 | 8) + struct.pack(">Q", info.st_size) + u32(info.st_mode) + u32(int(info.st_atime)) + u32(int(info.st_mtime))))
            elif kind == 10:
                name, at = take_string(body, at)
                (flags,) = struct.unpack_from(">I", body, at)
                if flags & 1 and int(name) in handles:
                    (size,) = struct.unpack_from(">Q", body, at + 4)
                    os.ftruncate(handles[int(name)], size)
                send_later(status(ident, 0))
            elif kind == 18:
                old, at = take_string(body, at)
                new, at = take_string(body, at)
                source = os.path.join(root, old.decode().lstrip("/"))
                target = os.path.join(root, new.decode().lstrip("/"))
                if os.path.lexists(target) or (mode == "strictrename" and old.decode().endswith("locked")):
                    send_later(status(ident, 4, "Failure"))
                else:
                    os.rename(source, target)
                    send_later(status(ident, 0))
            elif kind == 13:
                name, at = take_string(body, at)
                try:
                    os.remove(os.path.join(root, name.decode().lstrip("/")))
                    send_later(status(ident, 0))
                except OSError as error:
                    send_later(status(ident, 2 if error.errno == 2 else 4, str(error)))
            elif kind in (9, 10):
                send_later(status(ident, 0))
            else:
                send_later(status(ident, 8, "Not supported"))

        while True:
            wait = None
            if due:
                wait = max(0, due[0][0] - time.time())
            ready, _, _ = select.select([0], [], [], wait)
            if ready:
                chunk = os.read(0, 1 << 20)
                if not chunk:
                    break
                buffer += chunk
                while len(buffer) >= 4:
                    (length,) = struct.unpack_from(">I", buffer, 0)
                    if len(buffer) < 4 + length:
                        break
                    body = buffer[5:4 + length]
                    kind = buffer[4]
                    buffer = buffer[4 + length:]
                    handle(kind, body)
            while due and due[0][0] <= time.time():
                _, _, data = heapq.heappop(due)
                os.write(1, data)
        """
}

/// The SFTP client against the delaying test server: a window of requests, answers out of
/// order, short reads, failures, and requests that are never answered.
@Suite(.enabled(if: FakeSFTPServer.isAvailable)) struct NetworkFixSFTP {
    let box: Sandbox
    let center: ConnectionCenter
    let fileSystem: RemoteFileSystem
    let key = ServerKey(scheme: "sftp", host: "fake.invalid")

    init(mode: FakeSFTPServer.Mode = .normal, timeout: TimeInterval = 10) throws {
        box = try Sandbox()
        try box.folder("srv")
        let server = try FakeSFTPServer(root: box.url("srv"), box: box, mode: mode)
        let environment = SessionEnvironment()
        var values = NetworkOptions.Values()
        values.timeout = timeout
        environment.options.values = values
        center = ConnectionCenter(environment: environment)
        center.makeSession = { profile, environment in
            SFTPSession(profile: profile, environment: environment, transport: server.transport)
        }
        fileSystem = RemoteFileSystem(scheme: "sftp", center: center)
    }

    func url(_ path: String) -> URL { key.url(path: path) }

    static func pattern(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ $0 / 997) })
    }

    @Test func movesDataThroughTheWindowInBothDirections() throws {
        let content = Self.pattern(4_000_000)
        let started = Date()
        let writer = try fileSystem.write(url("/big.bin"))
        for start in stride(from: 0, to: content.count, by: 1_000_000) {
            try writer.write(content.subdata(in: start..<min(start + 1_000_000, content.count)))
        }
        try writer.close(attributes: FileAttributes())
        #expect(try Data(contentsOf: box.url("srv/big.bin")) == content)

        let reader = try fileSystem.read(url("/big.bin"))
        var read = Data()
        while let block = try reader.read(upToCount: 1 << 20) { read.append(block) }
        #expect(read == content)
        // Jumps and small reads, which the window must discard and restart.
        for position in [3_990_000, 17, 1_234_567, 1_234_568, 2_000_000, 40] {
            try reader.seek(to: UInt64(position))
            #expect(try reader.read(upToCount: 5_000) == content.subdata(in: position..<position + 5_000))
        }
        // Many small reads one after the other, the pattern of a viewer.
        try reader.seek(to: 100_000)
        var small = Data()
        for _ in 0..<60 { small.append(try #require(try reader.read(upToCount: 7_777))) }
        #expect(small == content.subdata(in: 100_000..<100_000 + 60 * 7_777))
        try reader.seek(to: UInt64(content.count))
        #expect(try reader.read(upToCount: 10) == nil)
        reader.close()
        // The requests overlapped: the server owed many answers at one moment. (One after the
        // other, 250 requests at 20 to 60 ms each would also take far longer than this did on an
        // idle machine; the time is not asserted, it says little on a busy one.)
        let peak = Int((try? String(contentsOf: box.url("sftp-peak.log"), encoding: .utf8)) ?? "") ?? 0
        #expect(
            peak >= 4,
            "at most \(peak) requests were unanswered at a time, after \(Date().timeIntervalSince(started)) s"
        )
    }

    @Test func aFailingReadDeliversWhatCameBeforeIt() throws {
        let suite = try Self(mode: .failingReads)
        let content = Self.pattern(300_000)
        try content.write(to: suite.box.url("srv/f.bin"))
        let reader = try suite.fileSystem.read(suite.url("/f.bin"))
        defer { reader.close() }
        var got = Data()
        var failed = false
        do {
            while let block = try reader.read(upToCount: 1 << 20) { got.append(block) }
        } catch {
            failed = true
        }
        #expect(failed && got == content.prefix(98_304))
    }

    @Test func aRequestThatTimesOutDoesNotCloseTheChannel() throws {
        let suite = try Self(mode: .hangingStat, timeout: 2)
        let content = Self.pattern(500_000)
        try content.write(to: suite.box.url("srv/f.bin"))
        let session = try suite.center.session(for: suite.key)
        _ = try session.connect(cancellation: nil)
        let reader = try suite.fileSystem.read(suite.url("/f.bin"))
        defer { reader.close() }
        #expect(try reader.read(upToCount: 10) == content.prefix(10))

        // The server goes on answering other requests while one of them hangs: it is slow with
        // that one, not gone. (A server that says nothing at all for the whole time is given
        // up; see `Review2NetworkSFTPTests`.)
        let stop = CancellationFlag()
        let asking = Thread {
            while !stop.isCancelled { _ = try? session.entry(at: "/f.bin") }
        }
        asking.start()
        defer { stop.cancel() }
        let started = Date()
        #expect(throws: NetworkError.self) { _ = try session.entry(at: "/hang") }
        // At the time limit of two seconds, not at some multiple of it.
        #expect(Date().timeIntervalSince(started) < 120)
        // The other transfer and new requests go on over the same channel.
        #expect(session.isConnected)
        var rest = content.prefix(10)
        while let block = try reader.read(upToCount: 1 << 20) { rest.append(block) }
        #expect(rest == content)
        #expect(try session.entry(at: "/f.bin")?.size == 500_000)
    }

    @Test func aStalledPipeFailsInsteadOfHanging() throws {
        let box = try Sandbox()
        let server = try FakeSFTPServer(root: box.url("."), box: box, mode: .stalled)
        let channel = SFTPChannel(
            executable: server.transport.executable,
            arguments: server.transport.arguments,
            environment: [:],
            writeTimeout: 1
        )
        try channel.start(timeout: Wait.ceiling, cancellation: nil) { true }
        defer { channel.close() }
        let started = Date()
        // A megabyte cannot be written into a pipe that nobody reads.
        #expect(throws: NetworkError.self) { _ = try channel.send(.write) { $0.bytes(Data(count: 1_000_000)) } }
        // After the second the write may take, not after a wait without end.
        #expect(Date().timeIntervalSince(started) < 120)
        #expect(channel.isClosed)
        // Later requests fail at once.
        #expect(throws: NetworkError.self) { _ = try channel.send(.read) { $0.bytes(Data()) } }
    }
}

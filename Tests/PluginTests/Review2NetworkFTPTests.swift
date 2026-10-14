import AFMKernel
import Foundation
@testable import NetworkPlugin
import TestSupport
import Testing

/// Collects what threads report, for a test to look at afterwards.
private final class Notes: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    func add(_ text: String) { lock.lock(); texts.append(text); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return texts }
}

/// Renaming onto an existing file never loses it (review 2: N005, N006, N007, N034).
@Suite struct Review2NetworkReplacingMove {
    private func fixture(_ configure: (inout TestFTPServer.Options) -> Void = { _ in }) throws -> FTPFixture {
        var options = TestFTPServer.Options()
        configure(&options)
        let fixture = try FTPFixture(options)
        try fixture.box.file("srv/new.txt", "new")
        try fixture.box.file("srv/keep.txt", "old")
        return fixture
    }

    private func leftovers(_ fixture: FTPFixture) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixture.box.url("srv").path).filter { $0.contains(".replaced-") }
    }

    @Test func aSourceThatDoesNotExistLeavesTheDestinationAlone() throws {
        let fixture = try fixture()
        #expect(throws: (any Error).self) {
            try fixture.fileSystem.move(fixture.url("/missing.txt"), to: fixture.url("/keep.txt"), replacing: true)
        }
        #expect(fixture.box.read("srv/keep.txt") == "old")
        #expect(!fixture.server.commands.contains { $0.hasPrefix("DELE") })
    }

    @Test func aServerThatReplacesDoesItInOneStep() throws {
        let fixture = try fixture()
        try fixture.fileSystem.move(fixture.url("/new.txt"), to: fixture.url("/keep.txt"), replacing: true)
        #expect(fixture.box.read("srv/keep.txt") == "new" && !fixture.box.exists("srv/new.txt"))
        #expect(fixture.server.commands.filter { $0.hasPrefix("RNTO") }.count == 1)
        #expect(!fixture.server.commands.contains { $0.hasPrefix("DELE") })
    }

    @Test func aServerThatDoesNotReplaceGetsTheOldFileMovedAside() throws {
        let fixture = try fixture { $0.renameKeepsExisting = true }
        try fixture.fileSystem.move(fixture.url("/new.txt"), to: fixture.url("/keep.txt"), replacing: true)
        #expect(fixture.box.read("srv/keep.txt") == "new" && !fixture.box.exists("srv/new.txt"))
        #expect(try leftovers(fixture).isEmpty)
        // The old file was deleted last, under its other name, never under its own.
        let commands = fixture.server.commands
        let deleted = commands.filter { $0.hasPrefix("DELE") }
        #expect(deleted.count == 1 && deleted[0].contains(".replaced-") && commands.last(where: { $0.hasPrefix("RNTO") }) == "RNTO /keep.txt")
        let (deletion, renaming) = (try #require(commands.firstIndex(of: deleted[0])), try #require(commands.lastIndex(of: "RNTO /keep.txt")))
        #expect(deletion > renaming)
        // The listings follow.
        #expect(try fixture.names("/") == ["keep.txt"])
    }

    @Test func aRenameThatIsRefusedForAnotherReasonLosesNothing() throws {
        // May delete, may not rename: the destination must not be the price.
        let fixture = try fixture { $0.refusesRenameOf = "*" }
        #expect(throws: NetworkError.self) {
            try fixture.fileSystem.move(fixture.url("/new.txt"), to: fixture.url("/keep.txt"), replacing: true)
        }
        #expect(fixture.box.read("srv/keep.txt") == "old" && fixture.box.read("srv/new.txt") == "new")
        #expect(!fixture.server.commands.contains { $0.hasPrefix("DELE") })
        #expect(try leftovers(fixture).isEmpty)
    }

    @Test func theOldFileIsPutBackWhenTheNewOneCannotTakeItsPlace() throws {
        // The file in the way can be moved aside, the new one cannot be renamed at all.
        let fixture = try fixture {
            $0.renameKeepsExisting = true
            $0.refusesRenameOf = "/new.txt"
        }
        #expect(throws: NetworkError.self) {
            try fixture.fileSystem.move(fixture.url("/new.txt"), to: fixture.url("/keep.txt"), replacing: true)
        }
        #expect(fixture.box.read("srv/keep.txt") == "old" && fixture.box.read("srv/new.txt") == "new")
        #expect(try leftovers(fixture).isEmpty)
        #expect(!fixture.server.commands.contains { $0.hasPrefix("DELE") })
    }

    @Test func aFolderInTheWayIsNotReplaced() throws {
        let fixture = try fixture { $0.renameKeepsExisting = true }
        try fixture.box.file("srv/dir/inside.txt", "i")
        #expect(throws: (any Error).self) {
            try fixture.fileSystem.move(fixture.url("/new.txt"), to: fixture.url("/dir"), replacing: true)
        }
        #expect(fixture.box.read("srv/dir/inside.txt") == "i" && fixture.box.read("srv/new.txt") == "new")
    }

    @Test func aNameThatDiffersOnlyInCaseIsAskedOfTheServer() throws {
        var options = TestFTPServer.Options()
        options.offersMLSD = false
        let fixture = try FTPFixture(options)
        try fixture.box.file("srv/file.txt", "there")
        _ = try fixture.names("/")
        // The listing knows `file.txt`. Whether `File.txt` is the same file is the server's to say
        // (this one, on a Mac's disk, says yes), not the listing's.
        #expect(throws: FileSystemError.self) { _ = try fixture.fileSystem.write(fixture.url("/File.txt")) }
        #expect(fixture.box.read("srv/file.txt") == "there")
        try fixture.box.file("srv/other.txt", "o")
        #expect(throws: FileSystemError.self) {
            try fixture.fileSystem.move(fixture.url("/other.txt"), to: fixture.url("/FILE.TXT"), replacing: false)
        }
        #expect(fixture.box.read("srv/file.txt") == "there")
    }

    @Test func aFileMadeBehindTheListingIsSeenWhereAskingIsCheap() throws {
        let fixture = try FTPFixture()
        _ = try fixture.names("/")
        // Made by somebody else a moment after the folder was read.
        try fixture.box.file("srv/fresh.txt", "theirs")
        #expect(throws: FileSystemError.self) { _ = try fixture.fileSystem.write(fixture.url("/fresh.txt")) }
        #expect(fixture.box.read("srv/fresh.txt") == "theirs")
    }
}

/// An upload is only a success when the server has all of it (review 2: N029).
@Suite struct Review2NetworkUploads {
    @Test func anUploadThatLostItsEndIsNotASuccess() throws {
        var options = TestFTPServer.Options()
        options.keepsOfUploads = 1000
        let fixture = try FTPFixture(options)
        let writer = try fixture.fileSystem.write(fixture.url("/up.bin"))
        try writer.write(Data(repeating: 7, count: 5000))
        // The server said 226.
        #expect(throws: NetworkError.self) { try writer.close(attributes: FileAttributes()) }
        fixture.server.options.keepsOfUploads = nil
        try fixture.upload("/whole.bin", Data(repeating: 7, count: 5000))
        #expect(fixture.server.commands.contains("SIZE /whole.bin"))
    }

    @Test func aServerThatTakesAppendForStoreIsNoticed() throws {
        var options = TestFTPServer.Options()
        options.appendStartsAnew = true
        let fixture = try FTPFixture(options)
        try fixture.box.file("srv/f.bin", "0123456789")
        let writer = try fixture.fileSystem.append(to: fixture.url("/f.bin"), at: nil, cancellation: CancellationFlag())
        try writer.write(Data("abc".utf8))
        // The file now holds only the tail; "resumed" it is not.
        #expect(throws: NetworkError.self) { try writer.close(attributes: FileAttributes()) }
    }

    @Test func withoutSIZETheLengthComesFromMLST() throws {
        var options = TestFTPServer.Options()
        (options.offersSize, options.keepsOfUploads) = (false, 10)
        let fixture = try FTPFixture(options)
        let writer = try fixture.fileSystem.write(fixture.url("/up.bin"))
        try writer.write(Data(repeating: 7, count: 500))
        #expect(throws: NetworkError.self) { try writer.close(attributes: FileAttributes()) }
    }
}

/// A server that sends what no server should (review 2: N004, N021, N023, N025, N073, N074).
@Suite struct Review2NetworkFTPHostile {
    @Test func aListingWithEndlessLinesGivesWhatIsReadable() throws {
        var options = TestFTPServer.Options()
        options.offersMLSD = false
        var raw = Data("-rw-r--r-- 1 o g 3 Jan 01 2020 first.txt\r\n".utf8)
        raw.append(Data("-rwxrwxrwx ".utf8) + Data(repeating: 0x39, count: 3_000_000) + Data("\r\n".utf8))
        raw.append(Data("-rw-r--r-- 1 o g 3 Jan 01 2020 second.txt\r\n".utf8))
        // And an end without a line end, also far too long.
        raw.append(Data(repeating: 0x39, count: 500_000))
        options.rawListing = raw
        let fixture = try FTPFixture(options)
        let started = Date()
        #expect(try fixture.names("/") == ["first.txt", "second.txt"])
        #expect(Date().timeIntervalSince(started) < 300)
        // The connection is in step: the next commands are answered by their own replies.
        fixture.server.options.rawListing = nil
        try fixture.box.file("srv/real.txt", "r")
        #expect(try fixture.names("/") == ["real.txt"])
        #expect(fixture.server.connectionsOpened == 1)
    }

    @Test func aReplyThatNeverEndsIsGivenUp() throws {
        let fixture = try FTPFixture { $0.timeout = 3 }
        _ = try fixture.names("/")
        fixture.server.options.endlessReplyTo = "MKD"
        let call = AdoptOutcome { try fixture.fileSystem.createDirectory(at: fixture.url("/made")) }
        #expect(call.ended(within: 120) && call.failed)
    }

    @Test func aReplyLineWithoutAnEndIsGivenUp() throws {
        let fixture = try FTPFixture { $0.timeout = 600 }
        _ = try fixture.names("/")
        fixture.server.options.longLineReplyTo = ("MKD", 2_000_000)
        let started = Date()
        let call = AdoptOutcome { try fixture.fileSystem.createDirectory(at: fixture.url("/made")) }
        // Not when the time for a reply is up: as soon as the line is longer than a line may be.
        #expect(call.ended(within: 120) && call.failed, "after \(Date().timeIntervalSince(started)) s")
    }

    @Test func aTransferAnnouncedTwiceLeavesTheConnectionInStep() throws {
        var options = TestFTPServer.Options()
        options.announcesTwice = true
        let fixture = try FTPFixture(options)
        try fixture.box.file("srv/a.txt", "abc")
        #expect(try fixture.names("/") == ["a.txt"])
        #expect(try fixture.download("/a.txt") == Data("abc".utf8))
        try fixture.upload("/b.txt", Data("b".utf8))
        #expect(try fixture.names("/") == ["a.txt", "b.txt"])
        #expect(fixture.server.connectionsOpened == 1, "no reply was left over to throw the next command off")
    }

    @Test func activeModeThatFailsDoesNotLeaveAReplyBehind() throws {
        var options = TestFTPServer.Options()
        options.activeNeverConnects = 0.2
        let fixture = try FTPFixture(options) {
            $0.passiveByDefault = false
            $0.timeout = 2
        }
        try fixture.box.file("srv/a.txt", "a")
        // The data connection never comes; the server says so after the announcement.
        #expect(throws: (any Error).self) { _ = try fixture.names("/") }
        // What follows is answered by its own replies, on the same connection or on a new one.
        fixture.server.options.activeNeverConnects = nil
        #expect(try fixture.names("/") == ["a.txt"])
        #expect(fixture.fileSystem.item(at: fixture.url("/a.txt"))?.size == 1)
        #expect(fixture.fileSystem.item(at: fixture.url("/none.txt")) == nil)

        // The same when the server says nothing more at all: that connection is not used again.
        fixture.server.options.activeNeverConnects = 30
        let opened = fixture.server.connectionsOpened
        #expect(throws: (any Error).self) { _ = try fixture.names("/") }
        fixture.server.options.activeNeverConnects = nil
        #expect(try fixture.names("/") == ["a.txt"])
        #expect(fixture.server.connectionsOpened > opened)
    }

    @Test func onlyTheServerMayOpenTheDataConnection() throws {
        func connect(to port: Int) -> Int32 {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            return descriptor
        }
        // The control connection goes to another machine: whoever connects from here is not the server.
        let guarded = try DataListener(peer: "192.0.2.7", local: "127.0.0.1")
        let port = try guarded.start(timeout: 10)
        let intruder = connect(to: port)
        defer { close(intruder) }
        #expect(throws: NetworkError.self) { _ = try guarded.accept(timeout: 1.5, cancellation: nil) }
        // The intruder was hung up on.
        var byte: UInt8 = 0
        var waiting = pollfd(fd: intruder, events: Int16(POLLIN), revents: 0)
        #expect(poll(&waiting, 1, 10_000) > 0 && recv(intruder, &byte, 1, 0) <= 0)

        // The server itself is let in.
        let open = try DataListener(peer: "127.0.0.1", local: "127.0.0.1")
        let server = connect(to: try open.start(timeout: 10))
        defer { close(server) }
        let stream = try open.accept(timeout: 10, cancellation: nil)
        stream.close()

        #expect(DataListener.comparable("::ffff:192.0.2.7") == "192.0.2.7" && DataListener.comparable("FE80::1%en0") == "fe80::1")
        #expect(DataListener.comparable("[::1]") == "::1")
    }

    @Test func namesInDecomposedFormGoBackAsTheyCame() throws {
        let fixture = try FTPFixture()
        // As a server stores a name that was made on an older Mac: `u` and a combining diaeresis.
        try fixture.box.file("srv/u\u{308}ber.txt", "content")
        let listed = try #require(try fixture.fileSystem.list(fixture.url("/"), showHidden: true).first)
        #expect(Array(listed.name.unicodeScalars).contains("\u{308}"))
        #expect(try fixture.download(listed.url.path) == Data("content".utf8))
        let sent = try #require(fixture.server.commands.first { $0.hasPrefix("RETR") })
        #expect(sent.unicodeScalars.contains("\u{308}"), "the name was sent composed, which is another name to a server that compares bytes")
        // A name that comes from the Mac is composed, as before.
        try fixture.upload("/o\u{308}.txt", Data("x".utf8))
        let stored = try #require(fixture.server.commands.first { $0.hasPrefix("STOR") })
        #expect(!stored.unicodeScalars.contains("\u{308}"))
    }
}

/// Every wait ends (review 2: N010, N012, N026, N027, N035, N044, N046, N049, N050, N052, N054).
@Suite struct Review2NetworkWaits {
    @Test func aWaitBehindAnotherLoginCanBeCancelled() throws {
        var options = TestFTPServer.Options()
        (options.user, options.password) = ("anna", "pw")
        let fixture = try FTPFixture(options)
        try fixture.box.file("srv/a.txt", "a")
        fixture.center.announce(ConnectionProfile(key: fixture.key, user: "anna"), chosen: true)
        // The first login sits at its password question for as long as the test lets it.
        let (asked, answer) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        fixture.environment.askCredentials = { _, _ in
            asked.signal()
            answer.wait()
            return Credentials(user: "anna", password: "pw")
        }
        let first = AdoptOutcome { _ = try fixture.names("/") }
        #expect(asked.wait(timeout: .now() + 30) == .success)

        // A second thread waits behind it, and leaves when it is cancelled.
        let flag = CancellationFlag()
        let second = AdoptOutcome { _ = try fixture.fileSystem.list(fixture.url("/"), showHidden: false, cancellation: flag) }
        #expect(!second.ended(within: 0.5))
        flag.cancel()
        #expect(second.ended(within: 120) && second.failed)

        // The main thread never waits behind a login at all: the question is answered there.
        // A thread that waits ends when the session is closed.
        let third = AdoptOutcome { try fixture.fileSystem.createDirectory(at: fixture.url("/made")) }
        #expect(!third.ended(within: 0.5))
        answer.signal()
        #expect(first.ended(within: 30) && !first.failed)
        #expect(third.ended(within: 30) && !third.failed && fixture.box.exists("srv/made"))
    }

    @Test func disconnectEndsAWaitThatHasNoFlag() throws {
        var options = TestFTPServer.Options()
        (options.user, options.password) = ("anna", "pw")
        let fixture = try FTPFixture(options)
        fixture.center.announce(ConnectionProfile(key: fixture.key, user: "anna"), chosen: true)
        let (asked, answer) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        fixture.environment.askCredentials = { _, _ in
            asked.signal()
            answer.wait()
            return nil
        }
        let session = try fixture.center.session(for: fixture.key)
        let first = AdoptOutcome { _ = try session.connect(cancellation: nil) }
        #expect(asked.wait(timeout: .now() + 30) == .success)
        // Called without a flag, it ends with the session.
        let waiting = AdoptOutcome { try session.makeDirectory("/made") }
        #expect(!waiting.ended(within: 0.5))
        let started = Date()
        session.disconnect()
        #expect(Date().timeIntervalSince(started) < 60, "closing returns at once")
        #expect(waiting.ended(within: 120) && waiting.failed)
        answer.signal()
        #expect(first.ended(within: 30) && first.failed)
    }

    @Test func filesHeldOpenDoNotMakeTheNextOneWaitForEver() throws {
        let fixture = try FTPFixture { $0.parallelConnections = 1 }
        // Large enough that a file that is not read on is not finished behind the reader's back.
        for index in 0..<3 { try Data(repeating: UInt8(index), count: 8_000_000).write(to: fixture.box.url("srv/f\(index).bin")) }
        let session = try #require(try fixture.center.session(for: fixture.key) as? FTPSession)
        session.stallLimit = 1
        // Two viewers that paused: all the connections downloads may have.
        let held = try (0..<2).map { index -> FileReader in
            let reader = try fixture.fileSystem.read(fixture.url("/f\(index).bin"))
            #expect(try reader.read(upToCount: 10)?.count == 10)
            return reader
        }
        let third = try fixture.fileSystem.read(fixture.url("/f2.bin"))
        let outcome = Notes()
        let call = AdoptOutcome {
            do {
                _ = try third.read(upToCount: 10)
            } catch {
                outcome.add(error.localizedDescription)
                throw error
            }
        }
        #expect(call.ended(within: 60) && call.failed)
        #expect(outcome.all.first?.contains("held by open files") == true, "\(outcome.all)")
        // Once one of them is closed there is room again.
        held[0].close()
        #expect(try third.read(upToCount: 10)?.count == 10)
        third.close()
        held[1].close()
    }

    @Test func aCancelledLoginIsNotRememberedAsARefusal() throws {
        var options = TestFTPServer.Options()
        options.greetingDelay = 2
        let fixture = try FTPFixture(options)
        fixture.environment.declineMemory = 600
        try fixture.box.file("srv/a.txt", "a")
        let flag = CancellationFlag()
        adoptCancel(flag, after: 0.3)
        #expect(throws: (any Error).self) { _ = try fixture.center.connect(fixture.key, cancellation: flag) }
        // The user tries again at once: the server is asked, the earlier cancel says nothing.
        #expect(try fixture.names("/") == ["a.txt"])

        // A question the user refused is remembered, so one click does not ask several times.
        var secured = TestFTPServer.Options()
        (secured.user, secured.password) = ("anna", "pw")
        let other = try FTPFixture(secured)
        other.environment.declineMemory = 600
        var questions = 0
        other.environment.askCredentials = { _, _ in
            questions += 1
            return nil
        }
        #expect(throws: (any Error).self) { _ = try other.names("/") }
        #expect(throws: (any Error).self) { _ = try other.names("/") }
        #expect(questions == 1)
    }

    @Test func closingAReaderReturnsAtOnceAndGivesTheConnectionBack() throws {
        let fixture = try FTPFixture { $0.parallelConnections = 1 }
        try Data(repeating: 1, count: 8_000_000).write(to: fixture.box.url("srv/big.bin"))
        try fixture.box.file("srv/small.txt", "s")
        let session = try #require(try fixture.center.session(for: fixture.key) as? FTPSession)
        for _ in 0..<6 {
            let reader = try fixture.fileSystem.read(fixture.url("/big.bin"))
            #expect(try reader.read(upToCount: 100)?.count == 100)
            // In the middle of the file: the server is told in the background.
            reader.close()
            // Closed twice, and read after closing: nothing happens.
            reader.close()
            #expect(try reader.read(upToCount: 10) == nil)
        }
        #expect(fixture.settle(session))
        // Every connection came back or was closed; none is lost to the pool, and none was cut
        // while another thread had it.
        #expect(try fixture.download("/small.txt") == Data("s".utf8))
        #expect(session.connectionCount <= 2)
        #expect(Background.threadCount <= Background.mostThreads)
    }

    @Test func closingWhileAnotherThreadUsesTheConnectionNextDoesNotCutIt() throws {
        // The reader reaches the end of its file and gives the connection back; `close` from
        // another thread comes at the same moment. Whoever takes the connection next must not
        // find it cut. Many rounds, since it is a race.
        let fixture = try FTPFixture { $0.parallelConnections = 1 }
        try fixture.box.file("srv/tiny.txt", "t")
        _ = try fixture.center.connect(fixture.key)
        let failures = Notes()
        for round in 0..<60 {
            let reader = try fixture.fileSystem.read(fixture.url("/tiny.txt"))
            let done = DispatchSemaphore(value: 0)
            Thread {
                do {
                    while try reader.read(upToCount: 100) != nil {}
                } catch {}
                done.signal()
            }.start()
            Thread {
                reader.close()
                done.signal()
            }.start()
            // Not retried when the connection is lost: a rename.
            do {
                try fixture.fileSystem.createDirectory(at: fixture.url("/d\(round)"))
            } catch {
                failures.add("round \(round): \(error.localizedDescription)")
            }
            #expect(done.wait(timeout: .now() + 30) == .success && done.wait(timeout: .now() + 30) == .success)
        }
        #expect(failures.all.isEmpty, "\(failures.all)")
    }

    @Test func manyDroppedTransfersDoNotPileUpThreads() throws {
        var options = TestFTPServer.Options()
        options.stallRETR = true
        let fixture = try FTPFixture(options) {
            $0.parallelConnections = 8
            $0.timeout = 2
        }
        try fixture.box.file("srv/f.bin", String(repeating: "z", count: 1000))
        // A server that stopped answering, and a viewer that steps through files: every reader
        // is dropped without being closed while its transfer hangs.
        for _ in 0..<24 {
            var reader: FileReader? = try fixture.fileSystem.read(fixture.url("/f.bin"))
            let pending = reader
            let read = AdoptOutcome { _ = try pending?.read(upToCount: 10) }
            reader?.interrupt()
            _ = read.ended(within: 30)
            reader = nil
        }
        #expect(Background.threadCount <= Background.mostThreads)
        #expect(fixture.settle())
    }

    @Test func keepAliveTestsOneConnectionAtATimeAndKeepsThePoolUsable() throws {
        let fixture = try FTPFixture {
            $0.keepAliveInterval = 0.5
            $0.parallelConnections = 3
        }
        try fixture.box.file("srv/a.txt", "a")
        // Three connections that then sit idle.
        DispatchQueue.concurrentPerform(iterations: 3) { _ in _ = try? fixture.names("/") }
        #expect(adoptWait(30) { fixture.server.commands.contains("NOOP") })
        // While they are being kept alive the pool answers as usual.
        for _ in 0..<5 { #expect(try fixture.names("/") == ["a.txt"]) }
        let session = try #require(try fixture.center.session(for: fixture.key) as? FTPSession)
        #expect(session.connectionCount <= 3)
        fixture.center.disconnect(fixture.key)
        #expect(fixture.settle(session))
    }

    @Test func linksAreResolvedByOneResolverThatStandsAside() throws {
        var options = TestFTPServer.Options()
        options.offersMLSD = false
        let fixture = try FTPFixture(options) { $0.parallelConnections = 1 }
        for folder in ["one", "two", "three"] {
            try fixture.box.folder("srv/\(folder)/d")
            for index in 0..<40 {
                try FileManager.default.createSymbolicLink(at: fixture.box.url("srv/\(folder)/link\(index)"),
                                                           withDestinationURL: fixture.box.url("srv/\(folder)/d"))
            }
        }
        // Three folders full of links, read one after the other with a single connection: the
        // listings do not wait for the questions about the links of the folders before.
        let started = Date()
        for folder in ["one", "two", "three"] { #expect(try fixture.names("/" + folder).count == 41) }
        #expect(Date().timeIntervalSince(started) < 120, "the listings waited for the background work")
        func resolved(_ folder: String) -> Bool {
            let links = (try? fixture.fileSystem.list(fixture.url("/" + folder), showHidden: false))?.filter(\.isSymlink) ?? []
            return links.count == 40 && links.allSatisfy(\.isDirectory)
        }
        // The last folder, the one the user is in, comes first.
        guard adoptWait(40, until: { resolved("three") }) else { try Test.cancel("the background work did not get through in time") }
        #expect(fixture.server.mostConnectionsAtOnce == 1)
        let session = try fixture.center.session(for: fixture.key)
        fixture.center.disconnect(fixture.key)
        #expect(fixture.settle(session))
    }
}

/// Who may connect where, and with what (review 2: N030, N031, N068, N071, N085, N087).
@Suite struct Review2NetworkConsent {
    @Test func aServerNobodyChoseIsAskedAbout() throws {
        let fixture = try FTPFixture()
        try fixture.box.file("srv/a.txt", "a")
        var asked: [ConnectionProfile] = []
        var allows = false
        fixture.environment.askToConnect = { profile in
            asked.append(profile)
            return allows
        }
        // A location from a tab file or a list: no login is made without the user's yes.
        #expect(throws: (any Error).self) { _ = try fixture.names("/") }
        #expect(asked.count == 1 && asked[0].key == fixture.key && asked[0].asksBeforeConnecting)
        #expect(!fixture.server.commands.contains { $0.hasPrefix("USER") })
        allows = true
        #expect(try fixture.names("/") == ["a.txt"])
        // Once for the session, not for every connection of it.
        DispatchQueue.concurrentPerform(iterations: 4) { _ in _ = try? fixture.names("/") }
        #expect(asked.count == 2)

        // A connection the user made in a dialog of the program is not asked about.
        let chosen = try FTPFixture()
        chosen.environment.askToConnect = { _ in
            asked.append(ConnectionProfile(key: chosen.key))
            return false
        }
        chosen.center.announce(ConnectionProfile(key: chosen.key, anonymous: true), chosen: true)
        #expect(try chosen.names("/").isEmpty && asked.count == 2)
        // Nor a saved one.
        let saved = try FTPFixture()
        saved.environment.askToConnect = { _ in false }
        saved.center.setSaved([ConnectionProfile(key: saved.key, savedID: UUID(), anonymous: true)])
        #expect(try saved.names("/").isEmpty)
    }

    @Test func aTypedAddressDoesNotDropALoginThatIsUnderWay() throws {
        var options = TestFTPServer.Options()
        (options.user, options.password) = ("anna", "pw")
        let fixture = try FTPFixture(options)
        try fixture.box.file("srv/a.txt", "a")
        let text = "ftp://anna@127.0.0.1:\(fixture.server.port)/"
        #expect(fixture.fileSystem.location(from: text) == fixture.url("/"))
        let (asked, answer) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        fixture.environment.askCredentials = { _, _ in
            asked.signal()
            answer.wait()
            return Credentials(user: "anna", password: "pw")
        }
        let login = AdoptOutcome { _ = try fixture.names("/") }
        #expect(asked.wait(timeout: .now() + 30) == .success)
        let session = try fixture.center.session(for: fixture.key)
        #expect(session.isConnecting)
        // The same text is read again while the user types the password (a panel that refreshes
        // its path field), and another with a password: the session at its question stays.
        #expect(fixture.fileSystem.location(from: text) == fixture.url("/"))
        #expect(fixture.fileSystem.location(from: "ftp://anna:other@127.0.0.1:\(fixture.server.port)/") == fixture.url("/"))
        #expect(try fixture.center.session(for: fixture.key) === session)
        answer.signal()
        #expect(login.ended(within: 30) && !login.failed)
        #expect(fixture.center.isConnected(fixture.key))
    }

    @Test func aPasswordOnPlainFTPIsAskedAboutAndStoredOnlyOnceAccepted() throws {
        var options = TestFTPServer.Options()
        (options.user, options.password) = ("anna", "right")
        let fixture = try FTPFixture(options)
        try fixture.box.file("srv/a.txt", "a")
        fixture.environment.asksAboutUnprotectedLoopback = true
        let id = UUID()
        fixture.center.setSaved([ConnectionProfile(key: fixture.key, savedID: id, user: "anna")])
        var warnings = 0
        var allows = false
        fixture.environment.askToSendPasswordUnprotected = { _ in
            warnings += 1
            return allows
        }
        var answers = ["wrong", "right"]
        fixture.environment.askCredentials = { _, _ in Credentials(user: "anna", password: answers.removeFirst(), remember: true) }
        var remembered: [String] = []
        fixture.environment.rememberPassword = { profile, password in
            if profile.savedID == id { remembered.append(password) }
        }
        // Refused: no password leaves the machine.
        #expect(throws: (any Error).self) { _ = try fixture.names("/") }
        #expect(warnings == 1 && !fixture.server.commands.contains { $0.hasPrefix("PASS") })
        answers = ["wrong", "right"]
        allows = true
        #expect(try fixture.names("/") == ["a.txt"])
        // Asked once, not for each attempt; and only the password the server took is kept.
        #expect(warnings == 2 && remembered == ["right"])
        #expect(fixture.server.commands.filter { $0.hasPrefix("PASS") } == ["PASS wrong", "PASS right"])
        #expect(FTPSession.isLoopback("127.0.0.1") && FTPSession.isLoopback("localhost") && FTPSession.isLoopback("::1"))
        #expect(!FTPSession.isLoopback("ftp.example.com") && !FTPSession.isLoopback("10.0.0.1"))
    }

    @Test func certificatesAcceptedForGoodAreNotReadFromTheSettings() {
        let trust = CertificateTrust()
        var loads = 0
        trust.load = {
            loads += 1
            return ["Files.Example.com": ["AA:BB"]]
        }
        // Nothing is fetched before a connection needs it.
        #expect(!trust.isAccepted("AA:BB", for: "files.example.com") && loads == 0)
        trust.prepare()
        trust.prepare()
        #expect(loads == 1 && trust.isAccepted("AA:BB", for: "FILES.example.com"))
        // A certificate that changed takes the place of the old one; it is not added to it.
        trust.accept("CC:DD", for: "files.example.com")
        #expect(trust.fingerprints(for: "files.example.com") == ["AA:BB", "CC:DD"])
        trust.replace(with: "EE:FF", for: "Files.example.com")
        #expect(trust.fingerprints(for: "files.example.com") == ["EE:FF"] && !trust.isAccepted("AA:BB", for: "files.example.com"))
    }
}

/// A certificate that is not the one accepted before (review 2: N030, N031).
@Suite(.enabled(if: TLSServer.isAvailable)) struct Review2NetworkChangedCertificate {
    @Test func aChangedCertificateIsAQuestionOfItsOwn() throws {
        // Two servers with two certificates under one host name: the second is what the first
        // looks like to somebody in the middle.
        let (firstBox, secondBox) = (try Sandbox(), try Sandbox())
        try firstBox.file("srv/first.txt", "1")
        try secondBox.file("srv/second.txt", "2")
        let first = try TLSServer(mode: .implicit, box: firstBox)
        let second = try TLSServer(mode: .implicit, box: secondBox)
        defer { first.stop(); second.stop() }

        let environment = SessionEnvironment()
        environment.declineMemory = 0
        var values = NetworkOptions.Values()
        (values.timeout, values.keepAliveInterval) = (10, 0)
        environment.options.values = values
        let center = ConnectionCenter(environment: environment)
        center.makeSession = { profile, environment in FTPSession(profile: profile, environment: environment) }
        let fileSystem = RemoteFileSystem(scheme: "ftps", center: center)
        defer { center.disconnectAll() }
        func key(_ server: TLSServer) -> ServerKey { ServerKey(scheme: "ftps", host: "127.0.0.1", port: server.port) }
        for server in [first, second] { center.announce(ConnectionProfile(key: key(server), tls: .implicit, anonymous: true), chosen: true) }

        var firstUse: [String] = []
        var changed: [(new: String, known: [String])] = []
        var acceptsChange = false
        environment.askToTrust = { profile, certificate in
            firstUse.append(certificate.fingerprint)
            environment.trust.accept(certificate.fingerprint, for: profile.key.host)
            return true
        }
        environment.askToTrustChanged = { profile, certificate, known in
            changed.append((certificate.fingerprint, known))
            if acceptsChange { environment.trust.replace(with: certificate.fingerprint, for: profile.key.host) }
            return acceptsChange
        }
        #expect(try fileSystem.list(key(first).url(), showHidden: true).map(\.name) == ["first.txt"])
        #expect(firstUse.count == 1 && changed.isEmpty)

        // The other certificate for the same host: not the question of a first visit, and refused it stays refused.
        #expect(throws: NetworkError.self) { _ = try fileSystem.list(key(second).url(), showHidden: true) }
        #expect(firstUse.count == 1 && changed.count == 1)
        #expect(changed[0].known == [firstUse[0]] && changed[0].new != firstUse[0])
        #expect(environment.trust.fingerprints(for: "127.0.0.1") == [firstUse[0]])

        // Accepted knowingly, it takes the old one's place.
        acceptsChange = true
        #expect(try fileSystem.list(key(second).url(), showHidden: true).map(\.name) == ["second.txt"])
        #expect(environment.trust.fingerprints(for: "127.0.0.1") == [changed[1].new])
    }
}

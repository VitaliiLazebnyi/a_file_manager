import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// A server that sends what no server should (review 2: N004, N021, N023, N025, N073, N074).
@Suite
internal struct Review2NetworkFTPHostile {
    /// A listing with lines of megabytes gives the lines that can be read, in reasonable time.
    @Test
    internal func aListingWithEndlessLinesGivesWhatIsReadable() throws {
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

    /// A reply whose lines never stop coming fails the command once the time for it is up.
    @Test
    internal func aReplyThatNeverEndsIsGivenUp() throws {
        let fixture = try FTPFixture { $0.timeout = 3 }
        _ = try fixture.names("/")
        fixture.server.options.endlessReplyTo = "MKD"
        let call = AdoptOutcome { try fixture.fileSystem.createDirectory(at: fixture.url("/made")) }
        #expect(call.ended() && call.failed)
    }

    /// A reply line that never ends fails the command as soon as it is longer than a line may be.
    @Test
    internal func aReplyLineWithoutAnEndIsGivenUp() throws {
        let fixture = try FTPFixture { $0.timeout = 600 }
        _ = try fixture.names("/")
        fixture.server.options.longLineReplyTo = ("MKD", 2_000_000)
        let started = Date()
        let call = AdoptOutcome { try fixture.fileSystem.createDirectory(at: fixture.url("/made")) }
        // Not when the time for a reply is up: as soon as the line is longer than a line may be.
        #expect(call.ended() && call.failed, "after \(Date().timeIntervalSince(started)) s")
    }

    /// A transfer announced with two preliminary replies leaves no reply over for the next command.
    @Test
    internal func aTransferAnnouncedTwiceLeavesTheConnectionInStep() throws {
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

    /// An active-mode transfer that never connects leaves no late reply to confuse what follows.
    @Test
    internal func activeModeThatFailsDoesNotLeaveAReplyBehind() throws {
        var options = TestFTPServer.Options()
        options.activeNeverConnects = 0.2
        let fixture = try FTPFixture(options) { values in
            values.passiveByDefault = false
            values.timeout = 2
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

    /// A data connection from anyone but the server's address is hung up on.
    @Test
    internal func onlyTheServerMayOpenTheDataConnection() throws {
        func connect(to port: Int) -> Int32 {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            return descriptor
        }
        // The control connection goes to another machine: whoever connects from here is not the server.
        let guarded = try DataListener(peer: "192.0.2.7", local: "127.0.0.1")
        let port = try guarded.start(timeout: Wait.ceiling)
        let intruder = connect(to: port)
        defer { close(intruder) }
        #expect(throws: NetworkError.self) { _ = try guarded.accept(timeout: 1.5, cancellation: nil) }
        // The intruder was hung up on.
        var byte: UInt8 = 0
        var waiting = pollfd(fd: intruder, events: Int16(POLLIN), revents: 0)
        #expect(poll(&waiting, 1, 10_000) > 0 && recv(intruder, &byte, 1, 0) <= 0)

        // The server itself is let in.
        let open = try DataListener(peer: "127.0.0.1", local: "127.0.0.1")
        let server = connect(to: try open.start(timeout: Wait.ceiling))
        defer { close(server) }
        let stream = try open.accept(timeout: Wait.ceiling, cancellation: nil)
        stream.close()

        #expect(
            DataListener.comparable("::ffff:192.0.2.7") == "192.0.2.7"
                && DataListener.comparable("FE80::1%en0") == "fe80::1"
        )
        #expect(DataListener.comparable("[::1]") == "::1")
    }

    /// A name the server lists decomposed is sent back decomposed; one from the Mac goes composed.
    @Test
    internal func namesInDecomposedFormGoBackAsTheyCame() throws {
        let fixture = try FTPFixture()
        // As a server stores a name that was made on an older Mac: `u` and a combining diaeresis.
        try fixture.box.file("srv/u\u{308}ber.txt", "content")
        let listed = try #require(try fixture.fileSystem.list(fixture.url("/"), showHidden: true).first)
        #expect(Array(listed.name.unicodeScalars).contains("\u{308}"))
        #expect(try fixture.download(listed.url.path) == Data("content".utf8))
        let sent = try #require(fixture.server.commands.first { $0.hasPrefix("RETR") })
        #expect(
            sent.unicodeScalars.contains("\u{308}"),
            "the name was sent composed, which is another name to a server that compares bytes"
        )
        // A name that comes from the Mac is composed, as before.
        try fixture.upload("/o\u{308}.txt", Data("x".utf8))
        let stored = try #require(fixture.server.commands.first { $0.hasPrefix("STOR") })
        #expect(!stored.unicodeScalars.contains("\u{308}"))
    }
}

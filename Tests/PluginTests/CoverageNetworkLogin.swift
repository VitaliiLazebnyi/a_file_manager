import AFMKernel
import Foundation
import Testing

@testable import NetworkPlugin

/// Logging in to FTP servers that delay, refuse or ask for more, and commands on a connection
/// that cannot take them.
@Suite
internal struct CoverageNetworkLogin {
    /// A delay announced before the greeting is waited for.
    @Test
    internal func aDelayAnnouncedBeforeTheGreetingIsWaitedFor() throws {
        let server = try CoverageNetworkServer(greeting: ["120 Busy for a moment", "220 Now ready"]) { _, _ in
            .standard
        }
        let connection = try server.connected()
        defer { connection.close() }
        #expect(connection.greeting == "Now ready")
    }

    /// A server that greets with something else is refused.
    @Test
    internal func aServerThatGreetsWithSomethingElseIsRefused() throws {
        let server = try CoverageNetworkServer(greeting: ["421 Too many users"]) { _, _ in .standard }
        let error = #expect(throws: NetworkError.self) { try server.connected() }
        #expect(CoverageNetworkServer.code(of: error) == 421)
    }

    /// A request for an account ends the login.
    @Test
    internal func aRequestForAnAccountEndsTheLogin() throws {
        let server = try CoverageNetworkServer(replies: ["USER": "332 Need account for login"])
        let error = #expect(throws: NetworkError.self) { try server.connected() }
        #expect(CoverageNetworkServer.text(of: error)?.contains("ACCT") == true)
    }

    /// A server that closes at the login refuses it; the password is not called wrong.
    @Test
    internal func aServerThatClosesAtTheLoginRefusesIt() throws {
        let server = try CoverageNetworkServer(replies: ["USER": "421 Service closing"])
        let error = #expect(throws: NetworkError.self) { try server.connected() }
        #expect(CoverageNetworkServer.code(of: error) == 421)
    }

    /// UTF-8 is asked for, and taken from the features when the server refuses the option.
    @Test
    internal func utf8IsAskedForAndTakenFromTheFeaturesWhenRefused() throws {
        let server = try CoverageNetworkServer(replies: ["OPTS": "501 No options"])
        let connection = try server.connected { config in
            config.encoding = .utf8
            config.initCommands = ["SITE UMASK 022"]
        }
        defer { connection.close() }
        #expect(connection.usesUTF8)
        #expect(server.commands.contains("OPTS UTF8 ON") && server.commands.contains("SITE UMASK 022"))
    }

    /// A closed connection takes no command, is not alive and tells nothing of links.
    @Test
    internal func aClosedConnectionTakesNoCommand() throws {
        let server = try CoverageNetworkServer(replies: [:])
        let connection = try server.connected()
        connection.close()
        #expect(throws: NetworkError.self) { try connection.send("NOOP") }
        #expect(!connection.isAlive())
        #expect(connection.probeLink("/link") == nil)
    }

    /// A reply without time left is a time-out, and the connection is not used again.
    @Test
    internal func aReplyWithoutTimeLeftIsATimeOutAndBreaksTheConnection() throws {
        let server = try CoverageNetworkServer(replies: [:])
        let connection = try server.connected()
        defer { connection.close() }
        let error = #expect(throws: NetworkError.self) { try connection.send("NOOP", replyWithin: 0) }
        #expect(CoverageNetworkServer.text(of: error) == "waiting for a reply")
        #expect(!connection.isUsable)
    }

    /// A name the encoding cannot write is not sent, and the connection stays usable.
    @Test
    internal func aNameTheEncodingCannotWriteIsNotSent() throws {
        let server = try CoverageNetworkServer(replies: [:])
        let connection = try server.connected { config in config.encoding = .isoLatin1 }
        defer { connection.close() }
        #expect(throws: FileSystemError.self) { try connection.send("CWD /\u{65E5}\u{672C}") }
        #expect(connection.isUsable && connection.isAlive())
    }

    /// A server that hangs up on NOOP is not alive.
    @Test
    internal func aServerThatHangsUpOnNOOPIsNotAlive() throws {
        let server = try CoverageNetworkServer(replies: ["NOOP": .hangUp])
        let connection = try server.connected()
        defer { connection.close() }
        #expect(!connection.isAlive())
    }

    /// MLST refusals other than "not found" are errors.
    @Test
    internal func mlstRefusalsOtherThanNotFoundAreErrors() throws {
        let server = try CoverageNetworkServer(replies: ["MLST /missing": "550 No such file", "MLST /odd": "500 What"])
        let connection = try server.connected()
        defer { connection.close() }
        #expect(try connection.status(of: "/missing") == nil)
        #expect(throws: NetworkError.self) { try connection.status(of: "/odd") }
    }

    /// Changing a date needs MFMT.
    @Test
    internal func changingADateNeedsMFMT() throws {
        let server = try CoverageNetworkServer(replies: [:])
        let connection = try server.connected()
        defer { connection.close() }
        #expect(throws: FileSystemError.self) { try connection.setModificationTime(Date(), of: "/a") }
    }
}

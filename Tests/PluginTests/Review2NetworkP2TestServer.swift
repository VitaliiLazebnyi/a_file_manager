import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// The test server itself: what the tests lean on when they run side by side.
@Suite
internal struct Review2NetworkP2TestServer {
    /// Servers started and stopped in a row refuse once stopped, and never disturb a server that keeps running.
    @Test
    internal func aStoppedServerTakesNoConnectionAndStoppingIsFinal() throws {
        let box = try Sandbox()
        try box.folder("srv")
        // Servers started and stopped in a row while others run: a stopped server's port
        // refuses, and stopping never touches a socket that is another server's by then.
        let steady = try FTPFixture()
        try steady.box.file("srv/a.txt", "a")
        for _ in 0..<40 {
            let server = try TestFTPServer(root: box.url("srv"), options: TestFTPServer.Options())
            let key = ServerKey(scheme: "ftp", host: "127.0.0.1", port: server.port)
            let center = ConnectionCenter(environment: SessionEnvironment())
            center.makeSession = { profile, environment in FTPSession(profile: profile, environment: environment) }
            center.noteChosen(key)
            let fileSystem = RemoteFileSystem(scheme: "ftp", center: center)
            #expect(try fileSystem.list(key.url(path: "/"), showHidden: false).isEmpty)
            server.stop()
            server.stop()
            #expect(server.isStopped)
            center.disconnectAll()
            #expect(throws: (any Error).self) { _ = try fileSystem.list(key.url(path: "/"), showHidden: false) }
            // The server that keeps running is not disturbed by the others coming and going.
            #expect(try steady.names("/") == ["a.txt"])
        }
        #expect(steady.server.connectionsOpened == 1)
    }

    /// A listing whose data connection the client never opens is answered with 425 as soon as it says more.
    @Test
    internal func aTransferTheClientGaveUpIsAnsweredWithoutWaitingForATimeLimit() throws {
        // The client asks for a listing and never opens the data connection, then says something
        // else: the server answers 425 at once and goes on, whatever the machine's load.
        let box = try Sandbox()
        try box.folder("srv")
        let server = try TestFTPServer(root: box.url("srv"), options: TestFTPServer.Options())
        defer { server.stop() }
        let stream = NetStream(host: "127.0.0.1", port: server.port, security: .plain)
        stream.start()
        defer { stream.close() }
        try stream.waitUntilReady(timeout: Wait.ceiling, cancellation: nil)
        func line() throws -> String {
            String(
                bytes: try stream.readLine(timeout: Wait.ceiling, limit: FTPLimits.lineLength, cancellation: nil),
                encoding: .utf8
            ) ?? ""
        }
        func say(_ text: String) throws {
            try stream.write(Data((text + "\r\n").utf8), timeout: Wait.ceiling, cancellation: nil)
        }
        #expect(try line().hasPrefix("220"))
        try say("USER anonymous")
        #expect(try line().hasPrefix("230"))
        try say("PASV")
        #expect(try line().hasPrefix("227"))
        try say("LIST")
        #expect(try line().hasPrefix("150"))
        try say("NOOP")
        #expect(try line().hasPrefix("425"))
        #expect(try line().hasPrefix("200"))
    }
}

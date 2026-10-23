import AFMKernel
import Foundation
import TestSupport

@testable import NetworkPlugin

/// A test server on a sandbox folder with the FTP file system connected to it.
///
/// Unchecked: set up in `init` and not changed afterwards; the server and the connections are safe
/// from any thread.
internal final class FTPFixture: @unchecked Sendable {
    /// The sandbox; the server serves its `srv` folder.
    internal let box: Sandbox
    /// The FTP server on 127.0.0.1.
    internal let server: TestFTPServer
    /// The connections to the server, whose sessions are FTP sessions.
    internal let center: ConnectionCenter
    /// The FTP file system over the center.
    internal let fileSystem: RemoteFileSystem
    /// The sessions' environment: options, questions and trust.
    internal var environment: SessionEnvironment { center.environment }

    /// The test server's key.
    internal var key: ServerKey { ServerKey(scheme: "ftp", host: "127.0.0.1", port: server.port) }

    /// A server with the default options and the tests' network options: a timeout of ten seconds, no
    /// keep-alive, nothing remembered of a refusal.
    internal convenience init() throws {
        try self.init(TestFTPServer.Options())
    }

    /// A server with the options given, and the tests' network options.
    internal convenience init(_ options: TestFTPServer.Options) throws {
        try self.init(options) { _ in
            // The tests' network options as they are.
        }
    }

    /// A server with the default options, and the tests' network options as `configure` changes them.
    internal convenience init(configure: (inout NetworkOptions.Values) -> Void) throws {
        try self.init(TestFTPServer.Options(), configure: configure)
    }

    /// A server with the options given, and the tests' network options as `configure` changes them.
    internal init(_ options: TestFTPServer.Options, configure: (inout NetworkOptions.Values) -> Void) throws {
        box = try Sandbox()
        try box.folder("srv")
        server = try TestFTPServer(root: box.url("srv"), options: options)
        let sessionEnvironment = SessionEnvironment()
        var values = NetworkOptions.Values()
        values.timeout = 10
        values.keepAliveInterval = 0
        configure(&values)
        sessionEnvironment.options.values = values
        sessionEnvironment.declineMemory = 0
        center = ConnectionCenter(environment: sessionEnvironment)
        center.makeSession = { profile, environment in FTPSession(profile: profile, environment: environment) }
        fileSystem = RemoteFileSystem(scheme: "ftp", center: center)
    }

    /// Waits until the background work of the fixture's session is done (connections given back, goodbyes
    /// said); false when it is not done in time.
    internal func settle() -> Bool {
        settle(nil)
    }

    /// Waits until the background work of this session (nil: the fixture's own) is done (connections given
    /// back, goodbyes said); false when it is not done in time.
    ///
    /// Of this session only: the tests run side by side, and the work of another test's server,
    /// which may be one that never answers, is not waited for.
    internal func settle(_ session: (any RemoteSession)?) -> Bool {
        guard let lane = session ?? center.existingSession(for: key) else {
            return true
        }
        return Background.waitUntilIdle(lane: lane, timeout: Wait.ceiling)
    }

    /// The location of a path on the server.
    internal func url(_ path: String) -> URL {
        key.url(path: path)
    }

    /// The names in a folder on the server, sorted, without hidden ones.
    internal func names(_ path: String) throws -> [String] {
        try names(path, showHidden: false)
    }

    /// The names in a folder on the server, sorted.
    internal func names(_ path: String, showHidden: Bool) throws -> [String] {
        try fileSystem.list(url(path), showHidden: showHidden).map(\.name).sorted()
    }

    /// A whole file from the server.
    internal func download(_ path: String) throws -> Data {
        try download(path, from: 0)
    }

    /// A file from the server, from an offset to its end.
    internal func download(_ path: String, from offset: UInt64) throws -> Data {
        let reader = try fileSystem.read(url(path))
        defer { reader.close() }
        if offset > 0 {
            try reader.seek(to: offset)
        }
        var data = Data()
        while let block = try reader.read(upToCount: 4_096) {
            data.append(block)
        }
        return data
    }

    /// Writes a new file on the server, with no attributes set.
    internal func upload(_ path: String, _ content: Data) throws {
        try upload(path, content, attributes: FileAttributes())
    }

    /// Writes a new file on the server and sets its attributes.
    internal func upload(_ path: String, _ content: Data, attributes: FileAttributes) throws {
        let writer = try fileSystem.write(url(path))
        try writer.write(content)
        try writer.close(attributes: attributes)
    }

    deinit {
        center.disconnectAll()
        server.stop()
    }
}

import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Continuing files over SFTP, against the system's own `sftp-server`.
@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: LocalSSHServer.systemSFTPServer)))
internal struct NetworkAdoptSFTPAppend {
    /// The sandbox whose files the server serves.
    internal let box: Sandbox
    /// The SFTP file system, whose sessions run `sftp-server -e` as their transport.
    internal let fileSystem: RemoteFileSystem
    /// The server; its host name is never looked up.
    internal let key = ServerKey(scheme: "sftp", host: "test.invalid")

    /// A file system on the system's SFTP server, with a time limit of ten seconds.
    internal init() throws {
        box = try Sandbox()
        let environment = SessionEnvironment()
        var values = NetworkOptions.Values()
        values.timeout = 10
        environment.options.values = values
        let center = ConnectionCenter(environment: environment)
        center.makeSession = { profile, environment in
            SFTPSession(
                profile: profile,
                environment: environment,
                transport: SFTPTransport(executable: LocalSSHServer.systemSFTPServer, arguments: ["-e"])
            )
        }
        fileSystem = RemoteFileSystem(scheme: "sftp", center: center)
    }

    /// The location of a path inside the sandbox, as the server sees it.
    internal func url(_ path: String) -> URL { key.url(path: box.url(path).path) }

    /// A file is continued from an offset, cut by a shorter continuation and appended to with permissions;
    /// an offset past the end and a missing file are errors.
    @Test
    internal func continuesCutsAndAppends() throws {
        try box.file("f.bin", "0123456789")
        #expect(fileSystem.capabilities(for: url("f.bin")).contains(.append))
        #expect(fileSystem.item(at: url("f.bin"))?.size == 10)

        var writer = try fileSystem.append(to: url("f.bin"), at: 4, cancellation: CancellationFlag())
        try writer.write(Data("abcdef".utf8))
        try writer.close(attributes: FileAttributes())
        #expect(box.read("f.bin") == "0123abcdef")
        #expect(fileSystem.item(at: url("f.bin"))?.size == 10)

        // A shorter continuation cuts the file: nothing of the old tail is left.
        writer = try fileSystem.append(to: url("f.bin"), at: 2, cancellation: CancellationFlag())
        try writer.write(Data("Z".utf8))
        try writer.close(attributes: FileAttributes())
        #expect(box.read("f.bin") == "01Z")
        #expect(fileSystem.item(at: url("f.bin"))?.size == 3)

        writer = try fileSystem.append(to: url("f.bin"), at: nil, cancellation: CancellationFlag())
        try writer.write(Data("+end".utf8))
        try writer.close(attributes: FileAttributes(permissions: 0o600))
        #expect(box.read("f.bin") == "01Z+end")
        #expect(fileSystem.item(at: url("f.bin"))?.size == 7 && fileSystem.item(at: url("f.bin"))?.permissions == 0o600)

        // Longer than the file, and not there: errors, and the file stays as it is.
        #expect(throws: (any Error).self) {
            _ = try fileSystem.append(to: url("f.bin"), at: 99, cancellation: CancellationFlag())
        }
        #expect(throws: (any Error).self) {
            _ = try fileSystem.append(to: url("none.bin"), at: nil, cancellation: CancellationFlag())
        }
        #expect(box.read("f.bin") == "01Z+end")
        #expect(!box.exists("none.bin"))
    }

    /// A continuation of nearly a megabyte goes through the window of requests whole.
    @Test
    internal func aLargeContinuationGoesThroughTheWindow() throws {
        let head = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let tail = Data((0..<900_000).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 3) })
        try head.write(to: box.url("big.bin"))
        let writer = try fileSystem.append(to: url("big.bin"), at: 100_000, cancellation: CancellationFlag())
        try writer.write(tail)
        try writer.close(attributes: FileAttributes())
        #expect(try Data(contentsOf: box.url("big.bin")) == head + tail)
    }
}

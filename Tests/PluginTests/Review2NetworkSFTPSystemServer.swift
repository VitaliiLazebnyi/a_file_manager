import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Renames, uploads and reads against the system's own SFTP server, run as the transport without ssh.
@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: LocalSSHServer.systemSFTPServer)))
internal struct Review2NetworkSFTPSystemServer {
    /// The folders the server works in.
    internal let box: Sandbox
    /// The connections, each made with the system's server.
    internal let center: ConnectionCenter
    /// The SFTP file system under test.
    internal let fileSystem: RemoteFileSystem
    /// The server's key; its host is never looked up.
    internal let key = ServerKey(scheme: "sftp", host: "test.invalid")

    /// A sandbox and a file system whose sessions run the system's server.
    internal init() throws {
        box = try Sandbox()
        let environment = SessionEnvironment()
        var values = NetworkOptions.Values()
        values.timeout = 10
        environment.options.values = values
        center = ConnectionCenter(environment: environment)
        center.makeSession = { profile, environment in
            SFTPSession(
                profile: profile,
                environment: environment,
                transport: SFTPTransport(executable: LocalSSHServer.systemSFTPServer, arguments: ["-e"])
            )
        }
        fileSystem = RemoteFileSystem(scheme: "sftp", center: center)
    }

    /// The address of `path` in the sandbox on the server (the server sees the whole disk).
    internal func url(_ path: String) -> URL { key.url(path: box.url(path).path) }

    /// A rename replaces only when asked to, also a file the listing does not know yet.
    @Test
    internal func renamingReplacesOnlyWhenAsked() throws {
        try box.file("new.txt", "new")
        try box.file("keep.txt", "old")
        _ = try fileSystem.list(url(""), showHidden: true)
        // A file made by somebody else after the folder was read: the listing does not know it,
        // the server does, and a rename that must not replace does not.
        try box.file("fresh.txt", "theirs")
        #expect(throws: FileSystemError.self) {
            try fileSystem.move(url("new.txt"), to: url("fresh.txt"), replacing: false)
        }
        #expect(box.read("fresh.txt") == "theirs" && box.read("new.txt") == "new")
        // Asked to replace, it does, in one step.
        try fileSystem.move(url("new.txt"), to: url("keep.txt"), replacing: true)
        #expect(box.read("keep.txt") == "new" && !box.exists("new.txt"))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: box.root.path).sorted() == ["fresh.txt", "keep.txt"]
        )
        // A source that does not exist loses nothing.
        #expect(throws: (any Error).self) {
            try fileSystem.move(url("none.txt"), to: url("keep.txt"), replacing: true)
        }
        #expect(box.read("keep.txt") == "new")
    }

    /// An upload arrives whole, and a name stored decomposed is found again as the listing showed it.
    @Test
    internal func uploadsAreMeasuredAndNamesGoBackAsTheyCame() throws {
        let content = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let writer = try fileSystem.write(url("up.bin"))
        try writer.write(content)
        try writer.close(
            attributes: FileAttributes(modified: Date(timeIntervalSince1970: 1_600_000_000), permissions: 0o640)
        )
        #expect(try Data(contentsOf: box.url("up.bin")) == content)
        #expect(fileSystem.item(at: url("up.bin"))?.size == 300_000)
        // A name stored decomposed is found again under the name the listing showed.
        try box.file("u\u{308}ber.txt", "content")
        let listed = try #require(
            try fileSystem.list(url(""), showHidden: true).first { $0.name.hasSuffix("ber.txt") }
        )
        let reader = try fileSystem.read(listed.url)
        #expect(try reader.read(upToCount: 100) == Data("content".utf8))
        reader.close()
        try fileSystem.remove(listed.url)
        #expect(!box.exists("u\u{308}ber.txt"))
    }

    /// Reading one page, jumping, and reading on gives the right bytes in each case.
    @Test
    internal func aViewerThatReadsOnePageAsksForOnePage() throws {
        let content = Data((0..<4_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try content.write(to: box.url("big.bin"))
        let reader = try fileSystem.read(url("big.bin"))
        // One page, a jump, one page: read correctly, without megabytes fetched ahead that
        // nobody wants (the window only opens for a caller that reads on).
        #expect(try reader.read(upToCount: 4_096) == content.prefix(4_096))
        try reader.seek(to: 3_000_000)
        #expect(try reader.read(upToCount: 4_096) == content.subdata(in: 3_000_000..<3_004_096))
        // Reading on from there gets the rest, through the window.
        var rest = Data()
        while let block = try reader.read(upToCount: 1 << 20) { rest.append(block) }
        #expect(rest == content.suffix(from: 3_004_096))
        reader.close()
    }
}

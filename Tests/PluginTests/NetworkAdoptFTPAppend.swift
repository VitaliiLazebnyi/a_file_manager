import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Continuing files against the FTP test server, and where the provider cannot.
@Suite
internal struct NetworkAdoptFTPAppend {
    /// A file is continued from an offset with REST, at its end with APPE, and at its length without REST;
    /// an offset past the end and a missing file are errors.
    @Test
    internal func continuesAFileInTheMiddleAtTheEndAndWhereItEnds() throws {
        let fixture = try FTPFixture()
        try fixture.box.file("srv/f.bin", "0123456789")
        let remote = fixture.fileSystem
        let url = fixture.url("/f.bin")
        #expect(remote.capabilities.contains(.append) && remote.capabilities(for: url).contains(.append))
        #expect(remote.item(at: url)?.size == 10)

        // Cut to four bytes, then the rest of the new content follows.
        var writer = try remote.append(to: url, at: 4, cancellation: CancellationFlag())
        try writer.write(Data("abcdef".utf8))
        try writer.close(attributes: FileAttributes())
        #expect(fixture.box.read("srv/f.bin") == "0123abcdef")
        #expect(remote.item(at: url)?.size == 10)
        #expect(fixture.server.commands.contains("REST 4") && fixture.server.commands.contains("STOR /f.bin"))

        // Without an offset it goes on at the end.
        writer = try remote.append(to: url, at: nil, cancellation: CancellationFlag())
        try writer.write(Data("XY".utf8))
        try writer.close(attributes: FileAttributes())
        #expect(fixture.box.read("srv/f.bin") == "0123abcdefXY")
        #expect(remote.item(at: url)?.size == 12)
        #expect(fixture.server.commands.contains("APPE /f.bin"))

        // An offset that is the length takes the same way, without REST.
        let restsBefore = fixture.server.commands.filter { $0.hasPrefix("REST") }.count
        writer = try remote.append(to: url, at: 12, cancellation: CancellationFlag())
        try writer.write(Data("Z".utf8))
        try writer.close(attributes: FileAttributes())
        #expect(fixture.box.read("srv/f.bin") == "0123abcdefXYZ")
        #expect(fixture.server.commands.filter { $0.hasPrefix("REST") }.count == restsBefore)
        #expect(remote.item(at: url)?.size == 13)

        // A file that is shorter than the offset, and one that is not there, are errors.
        #expect(throws: (any Error).self) { _ = try remote.append(to: url, at: 99, cancellation: CancellationFlag()) }
        #expect(throws: (any Error).self) {
            _ = try remote.append(to: fixture.url("/none.bin"), at: nil, cancellation: CancellationFlag())
        }
        #expect(fixture.box.read("srv/f.bin") == "0123abcdefXYZ")
    }

    /// A continuation shorter than the old tail is an error, as FTP cannot cut the file.
    @Test
    internal func aServerThatKeepsTheTailIsReportedNotTrusted() throws {
        let fixture = try FTPFixture()
        try fixture.box.file("srv/f.bin", "0123456789")
        // The new content is shorter than what lay behind the offset, and FTP cannot cut a file.
        let writer = try fixture.fileSystem.append(to: fixture.url("/f.bin"), at: 4, cancellation: CancellationFlag())
        try writer.write(Data("abc".utf8))
        #expect(throws: (any Error).self) { try writer.close(attributes: FileAttributes()) }
    }

    /// Without REST, and in text mode, the file system cannot continue files; other schemes' locations get
    /// its general capabilities.
    @Test
    internal func withoutRESTAndInTextModeTheCapabilityIsMissing() throws {
        var options = TestFTPServer.Options()
        options.offersREST = false
        let fixture = try FTPFixture(options)
        try fixture.box.file("srv/f.bin", "0123456789")
        let url = fixture.url("/f.bin")
        // Before the first login nothing is known and the provider's answer stands.
        #expect(fixture.fileSystem.capabilities(for: url).contains(.append))
        _ = try fixture.fileSystem.list(fixture.url("/"), showHidden: false)
        #expect(!fixture.fileSystem.capabilities(for: url).contains(.append))
        #expect(fixture.fileSystem.capabilities(for: url).contains(.write))
        #expect(throws: FileSystemError.self) {
            _ = try fixture.fileSystem.append(to: url, at: 4, cancellation: CancellationFlag())
        }
        #expect(fixture.box.read("srv/f.bin") == "0123456789")

        let text = try FTPFixture { $0.transferMode = .text }
        _ = try text.fileSystem.list(text.url("/"), showHidden: false)
        #expect(!text.fileSystem.capabilities(for: text.url("/f.txt")).contains(.append))
        #expect(throws: FileSystemError.self) {
            _ = try text.fileSystem.append(to: text.url("/f.txt"), at: nil, cancellation: CancellationFlag())
        }
        // Another scheme's location is not this provider's business.
        #expect(text.fileSystem.capabilities(for: URL(fileURLWithPath: "/tmp")) == text.fileSystem.capabilities)
    }
}

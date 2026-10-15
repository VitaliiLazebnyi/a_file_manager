import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// The calls that change something on an SFTP server.
@Suite(.enabled(if: FakeSFTPServer.isAvailable))
internal struct CovNetSFTPChanges {
    /// Removing what nobody said is a folder, and is not there, asks first and fails.
    @Test
    internal func removingSomethingThatIsNotThereAsksFirstAndFails() throws {
        let bench = try CovNetSFTPBench()
        let session = bench.session()
        defer { session.disconnect() }
        #expect(throws: SFTPError.self) { try session.remove("/missing", isDirectory: nil, cancellation: nil) }
        #expect(bench.requests.suffix(2) == ["7", "13"])
    }

    /// The date of a file is sent with its permissions.
    @Test
    internal func theDateIsSentWithThePermissions() throws {
        let bench = try CovNetSFTPBench()
        try bench.box.file("srv/f.txt", "x")
        let session = bench.session()
        defer { session.disconnect() }
        let attributes = FileAttributes(modified: Date(timeIntervalSince1970: 1_600_000_000), permissions: 0o640)
        try session.setAttributes(attributes, of: "/f.txt", cancellation: nil)
        #expect(bench.requests.last == "9")
    }

    /// A file whose length the server does not tell is continued from its start.
    @Test
    internal func aFileOfAnUntoldLengthIsContinuedFromItsStart() throws {
        let bench = try CovNetSFTPBench(mode: .noSize)
        try bench.box.file("srv/f.txt", "old text")
        let session = bench.session()
        defer { session.disconnect() }
        let (writer, size) = try session.openAppend("/f.txt", at: nil, cancellation: nil)
        #expect(size == 0)
        try writer.write(Data("new".utf8))
        try writer.close(attributes: FileAttributes())
        #expect(bench.box.read("srv/f.txt") == "new text")
    }
}

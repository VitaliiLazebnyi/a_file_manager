import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// An upload is only a success when the server has all of it (review 2: N029).
@Suite
internal struct Review2NetworkUploads {
    /// A server that kept only part of an upload but said 226 makes the upload fail.
    @Test
    internal func anUploadThatLostItsEndIsNotASuccess() throws {
        var options = TestFTPServer.Options()
        options.keepsOfUploads = 1_000
        let fixture = try FTPFixture(options)
        let writer = try fixture.fileSystem.write(fixture.url("/up.bin"))
        try writer.write(Data(repeating: 7, count: 5_000))
        // The server said 226.
        #expect(throws: NetworkError.self) { try writer.close(attributes: FileAttributes()) }
        fixture.server.options.keepsOfUploads = nil
        try fixture.upload("/whole.bin", Data(repeating: 7, count: 5_000))
        #expect(fixture.server.commands.contains("SIZE /whole.bin"))
    }

    /// A server that starts the file anew on APPE is caught: the resumed file would lose its start.
    @Test
    internal func aServerThatTakesAppendForStoreIsNoticed() throws {
        var options = TestFTPServer.Options()
        options.appendStartsAnew = true
        let fixture = try FTPFixture(options)
        try fixture.box.file("srv/f.bin", "0123456789")
        let writer = try fixture.fileSystem.append(
            to: fixture.url("/f.bin"),
            at: nil,
            cancellation: CancellationFlag()
        )
        try writer.write(Data("abc".utf8))
        // The file now holds only the tail; "resumed" it is not.
        #expect(throws: NetworkError.self) { try writer.close(attributes: FileAttributes()) }
    }

    /// Without SIZE the length of the upload is checked with MLST.
    @Test
    internal func withoutSIZETheLengthComesFromMLST() throws {
        var options = TestFTPServer.Options()
        (options.offersSize, options.keepsOfUploads) = (false, 10)
        let fixture = try FTPFixture(options)
        let writer = try fixture.fileSystem.write(fixture.url("/up.bin"))
        try writer.write(Data(repeating: 7, count: 500))
        #expect(throws: NetworkError.self) { try writer.close(attributes: FileAttributes()) }
    }
}

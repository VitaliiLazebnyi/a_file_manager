import AFMKernel
import Foundation
import Testing

@testable import NetworkPlugin

/// Uploads to an FTP server: closed twice, broken, interrupted, checked with MLST, and
/// servers that do not change permissions.
@Suite
internal struct CoverageNetworkWriters {
    /// A STOR that takes everything and confirms it.
    private static let store: CoverageNetworkServer.Answer = .act { line in
        line.send("150 Send it")
        _ = line.receiveData()
        line.send("226 Stored")
    }

    /// A STOR whose data connection the server drops at once.
    private static let drop: CoverageNetworkServer.Answer = .act { line in
        line.send("150 Send it")
        if let channel = line.acceptData() {
            close(channel)
        }
        line.send("426 Connection closed")
    }

    /// A server without chmod is asked once; a closed upload takes no more data.
    @Test
    internal func aServerWithoutChmodIsAskedOnce() throws {
        let server = try CoverageNetworkServer(replies: ["STOR": Self.store])
        let session = try server.session()
        defer { session.disconnect() }
        for name in ["/a", "/b"] {
            let writer = try session.openWrite(name, cancellation: nil)
            try writer.write(Data("hello".utf8))
            try writer.close(attributes: FileAttributes(permissions: 0o600))
            try writer.close(attributes: FileAttributes())
            #expect(throws: NetworkError.self) { try writer.write(Data("more".utf8)) }
        }
        #expect(server.commands.filter { $0.hasPrefix("SITE CHMOD") } == ["SITE CHMOD 600 /a"])
    }

    /// A chmod the server refuses for the file itself does not fail the upload.
    @Test
    internal func aRefusedChmodDoesNotFailTheUpload() throws {
        let server = try CoverageNetworkServer(replies: ["STOR": Self.store, "SITE": "550 Not allowed"])
        let session = try server.session()
        defer { session.disconnect() }
        for name in ["/a", "/b"] {
            let writer = try session.openWrite(name, cancellation: nil)
            try writer.close(attributes: FileAttributes(permissions: 0o600))
        }
        #expect(server.commands.filter { $0.hasPrefix("SITE CHMOD") }.count == 2)
    }

    /// The length of an upload is checked with MLST where the server has no SIZE.
    @Test
    internal func theLengthIsCheckedWithMLST() throws {
        let server = try CoverageNetworkServer(
            replies: [
                "STOR": Self.store, "FEAT": "211-Features:\r\n MLST type*;size*;\r\n211 End",
                "MLST /a": "250-Listing\r\n type=file;size=5; /a\r\n250 End",
                "MLST /b": "250-Listing\r\n type=file;size=9; /b\r\n250 End"
            ]
        )
        let session = try server.session()
        defer { session.disconnect() }
        let good = try session.openWrite("/a", cancellation: nil)
        try good.write(Data("hello".utf8))
        try good.close(attributes: FileAttributes())
        let short = try session.openWrite("/b", cancellation: nil)
        try short.write(Data("hello".utf8))
        let error = #expect(throws: NetworkError.self) { try short.close(attributes: FileAttributes()) }
        #expect(CoverageNetworkServer.text(of: error)?.contains("has 9 bytes after the upload, not 5") == true)
    }

    /// An upload whose write failed is closed without another error; an interrupted one says so.
    @Test
    internal func failedAndInterruptedUploadsAreClosed() throws {
        let server = try CoverageNetworkServer(replies: ["STOR": Self.drop])
        let session = try server.session()
        defer { session.disconnect() }
        let failing = try session.openWrite("/a", cancellation: nil)
        let block = Data(count: 1 << 20)
        #expect(throws: (any Error).self) {
            for _ in 0..<256 {
                try failing.write(block)
            }
        }
        try failing.close(attributes: FileAttributes())
        let interrupted = try session.openWrite("/b", cancellation: nil)
        interrupted.interrupt()
        #expect(throws: NetworkError.self) { try interrupted.write(Data("x".utf8)) }
        #expect(throws: NetworkError.self) { try interrupted.close(attributes: FileAttributes()) }
    }
}

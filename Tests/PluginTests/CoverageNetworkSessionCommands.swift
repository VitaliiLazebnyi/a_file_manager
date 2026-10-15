import AFMKernel
import Foundation
import Testing

@testable import NetworkPlugin

/// An FTP session on servers without MLST, without SIZE or without chmod: what it finds out
/// about single entries, and how it continues and removes files.
@Suite
internal struct CoverageNetworkSessionCommands {
    /// A listing of `/` with one file, `odd.txt`, of 9 bytes.
    private static let rootListing: CoverageNetworkServer.Answer = .act { line in
        line.transfer(Data("-rw-r--r-- 1 u g 9 Jan 01 2020 odd.txt\r\n".utf8), verdict: "226 Done")
    }

    /// Without MLST an entry is found by its size, by entering it, or in its folder's listing.
    @Test
    internal func withoutMLSTAnEntryIsFoundStepByStep() throws {
        let server = try CoverageNetworkServer(
            replies: [
                "SIZE /f.txt": "213 12", "MDTM /f.txt": "213 20240102030405",
                "SIZE /dir": "550 Not a file", "SIZE /odd.txt": "550 Not here", "SIZE /none": "550 Not here",
                "CWD /odd.txt": "550 No", "CWD /none": "550 No", "LIST": Self.rootListing
            ]
        )
        let session = try server.session()
        defer { session.disconnect() }
        #expect(try session.entry(at: "/", cancellation: nil)?.isDirectory == true)
        let file = try session.entry(at: "/f.txt", cancellation: nil)
        #expect(file?.size == 12 && file?.modified == Date(timeIntervalSince1970: 1_704_164_645))
        #expect(try session.entry(at: "/dir", cancellation: nil)?.isDirectory == true)
        #expect(try session.entry(at: "/odd.txt", cancellation: nil)?.size == 9)
        #expect(try session.entry(at: "/none", cancellation: nil) == nil)
    }

    /// A file that is no folder is reported with the server's answer about the file.
    @Test
    internal func aFileThatIsNoFolderIsReportedAsAFile() throws {
        let server = try CoverageNetworkServer(
            replies: ["DELE /x": "550 Permission denied", "RMD /x": "550 Not a directory"]
        )
        let session = try server.session()
        defer { session.disconnect() }
        let error = #expect(throws: NetworkError.self) { try session.remove("/x", isDirectory: nil, cancellation: nil) }
        guard case .refused(let reply) = error else {
            Issue.record("not refused: \(String(describing: error))")
            return
        }
        #expect(reply.text == "Permission denied")
    }

    /// A cancelled flag opens no file.
    @Test
    internal func aCancelledFlagOpensNoFile() throws {
        let server = try CoverageNetworkServer(replies: [:])
        let session = try server.session()
        let flag = CancellationFlag()
        flag.cancel()
        #expect(throws: NetworkError.self) { try session.openRead("/a", cancellation: flag) }
        #expect(server.commands.isEmpty)
    }

    /// A text file is not continued; without SIZE the length comes from the listing, and
    /// without REST a file is not continued in the middle.
    @Test
    internal func whatCannotBeContinued() throws {
        let listing: CoverageNetworkServer.Answer = .act { line in
            line.transfer(Data("-rw-r--r-- 1 u g 9 Jan 01 2020 odd.bin\r\n".utf8), verdict: "226 Done")
        }
        let server = try CoverageNetworkServer(
            replies: ["FEAT": "211-Features:\r\n MDTM\r\n211 End", "CWD": "550 No", "LIST": listing]
        )
        let center = server.center { values in values.transferMode = .automatic }
        let session = try center.session(for: server.key)
        defer { session.disconnect() }
        #expect(throws: FileSystemError.self) { try session.openAppend("/notes.txt", at: nil, cancellation: nil) }
        let missing = #expect(throws: NetworkError.self) {
            try session.openAppend("/missing.bin", at: nil, cancellation: nil)
        }
        #expect(CoverageNetworkServer.code(of: missing) == 550)
        let error = #expect(throws: FileSystemError.self) {
            try session.openAppend("/odd.bin", at: 3, cancellation: nil)
        }
        #expect(error?.localizedDescription.contains("Continuing a file on this server") == true)
        #expect(!server.commands.contains { $0.hasPrefix("REST") || $0.hasPrefix("STOR") })
    }
}

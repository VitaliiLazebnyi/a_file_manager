import AFMKernel
import Foundation
import Testing

@testable import NetworkPlugin

/// Listings of one FTP connection: other encodings, links, and listings stopped half-way.
@Suite
internal struct CoverageNetworkLinkListings {
    /// One line of a listing.
    private static let line = "-rw-r--r-- 1 u g 5 Jan 01 2020 a\r\n"

    /// A server that sends `line` as the listing and keeps the data connection open until the
    /// client drops it, then answers with 426.
    private func slowLister() throws -> CoverageNetworkServer {
        try CoverageNetworkServer(
            replies: [
                "LIST": .act { line in
                    line.sendAndWaitForTheClient(Data(Self.line.utf8))
                    line.send("426 Listing aborted")
                }
            ]
        )
    }

    /// Names in another encoding are remembered, and a last line without its end is read.
    @Test
    internal func namesInAnotherEncodingAreRememberedAndALastLineWithoutEndIsRead() throws {
        var data = Data("-rw-r--r-- 1 u g 5 Jan 01 2020 plain.txt\r\n-rw-r--r-- 1 u g 5 Jan 01 2020 caf".utf8)
        data.append(0xE9)
        let listing = data
        // A server that knows nothing of UTF-8.
        let server = try CoverageNetworkServer(
            replies: [
                "LIST": .act { line in line.transfer(listing, verdict: "226 Done") },
                "FEAT": "211-Features:\r\n SIZE\r\n211 End",
                "OPTS": "501 No options"
            ]
        )
        let connection = try server.connected()
        defer { connection.close() }
        var names: [String] = []
        try connection.list("/", showHidden: false) { entries in
            names += entries.map(\.name)
            return true
        }
        #expect(names == ["plain.txt", "caf\u{E9}"])
        #expect(connection.knownNames.encoding(of: Array("caf\u{E9}".utf8)) == .windowsCP1252)
    }

    /// Where a link leads is asked with MLST.
    @Test
    internal func whereALinkLeadsIsAskedWithMLST() throws {
        let link = Data("lrwxrwxrwx 1 u g 4 Jan 01 2020 docs -> elsewhere\r\n".utf8)
        let server = try CoverageNetworkServer(
            replies: [
                "FEAT": "211-Features:\r\n MLST type*;\r\n211 End",
                "LIST": .act { line in line.transfer(link, verdict: "226 Done") },
                "MLST /docs": "250-Listing\r\n type=dir; /elsewhere\r\n250 End"
            ]
        )
        let connection = try server.connected { config in config.usesMLSD = false }
        defer { connection.close() }
        var entries: [RemoteEntry] = []
        try connection.list("/", showHidden: false) { more in
            entries += more
            return true
        }
        #expect(entries.map(\.name) == ["docs"] && entries.first?.isDirectory == true)
    }

    /// A listing the receiver stops is aborted, and the connection stays usable.
    @Test
    internal func aListingTheReceiverStopsIsAborted() throws {
        let server = try slowLister()
        let connection = try server.connected()
        defer { connection.close() }
        var calls = 0
        try connection.list("/", showHidden: true) { _ in
            calls += 1
            return false
        }
        #expect(calls == 1 && connection.isUsable)
        #expect(server.commands.contains("LIST -la"))
    }

    /// A listing cancelled in the receiver is dropped with its connection.
    @Test
    internal func aListingCancelledInTheReceiverIsDropped() throws {
        let server = try slowLister()
        let connection = try server.connected()
        defer { connection.close() }
        let flag = CancellationFlag()
        try connection.list("/", showHidden: false, cancellation: flag) { _ in
            flag.cancel()
            return false
        }
        #expect(!connection.isUsable)
    }

    /// A listing cancelled while it waits for more is dropped with its connection.
    @Test
    internal func aListingCancelledWhileItWaitsIsDropped() throws {
        let server = try slowLister()
        let connection = try server.connected()
        defer { connection.close() }
        let flag = CancellationFlag()
        #expect(throws: NetworkError.self) {
            try connection.list("/", showHidden: false, cancellation: flag) { _ in
                flag.cancel()
                return true
            }
        }
        #expect(!connection.isUsable)
    }

    /// A listing that times out is aborted, and the connection stays usable.
    @Test
    internal func aListingThatTimesOutIsAborted() throws {
        let server = try slowLister()
        let connection = try server.connected { config in config.timeout = 1 }
        defer { connection.close() }
        let error = #expect(throws: NetworkError.self) {
            try connection.list("/", showHidden: false) { _ in true }
        }
        #expect(CoverageNetworkServer.text(of: error) == "reading")
        #expect(connection.isUsable)
    }
}

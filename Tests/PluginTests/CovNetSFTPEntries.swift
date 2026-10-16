import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Entries and listings over SFTP: links, and links whose targets are not told.
@Suite(.enabled(if: FakeSFTPServer.isAvailable))
internal struct CovNetSFTPEntries {
    /// The top of the server is a folder named `/`.
    @Test
    internal func theTopIsAFolderNamedSlash() throws {
        let bench = try CovNetSFTPBench()
        let session = bench.session()
        defer { session.disconnect() }
        let top = try #require(try session.entry(at: "/", cancellation: nil))
        #expect(top.name == "/" && top.isDirectory)
    }

    /// A link is a folder when it leads to one; one whose target is gone or not told is a link to a file.
    @Test
    internal func aLinkIsAFolderWhenItLeadsToOne() throws {
        let bench = try CovNetSFTPBench(mode: .links)
        try bench.box.folder("srv/folder")
        try bench.link("tofolder", to: "folder")
        try bench.link("gone", to: "nothing")
        try bench.link("xdeny", to: "folder")
        let session = bench.session()
        defer { session.disconnect() }
        let folder = try #require(try session.entry(at: "/tofolder", cancellation: nil))
        #expect(folder.isSymlink && folder.isDirectory && folder.name == "tofolder")
        for name in ["gone", "xdeny"] {
            let entry = try #require(try session.entry(at: "/\(name)", cancellation: nil))
            #expect(entry.isSymlink && !entry.isDirectory)
        }
    }

    /// Waiting for where a link leads ends with the caller's flag.
    @Test
    internal func waitingForWhereALinkLeadsEndsWithTheFlag() throws {
        let bench = try CovNetSFTPBench(mode: .links)
        try bench.link("xhang", to: ".")
        let session = bench.session()
        defer { session.disconnect() }
        let flag = CancellationFlag()
        let looking = AdoptOutcome { _ = try session.entry(at: "/xhang", cancellation: flag) }
        #expect(Wait.until { bench.requests.contains("17") })
        flag.cancel()
        #expect(looking.ended() && CovNetErrorKind(looking.thrown) == .cancelled)
    }

    /// A listing tells which links lead to folders; a link whose target is refused is listed all the same.
    @Test
    internal func aListingTellsWhichLinksLeadToFolders() throws {
        let bench = try CovNetSFTPBench(mode: .links)
        try bench.box.folder("srv/folder")
        try bench.box.file("srv/file.txt", "text")
        try bench.link("tofolder", to: "folder")
        try bench.link("xdeny", to: "folder")
        let session = bench.session()
        defer { session.disconnect() }
        var batches: [[RemoteEntry]] = []
        try session.list("/", showHidden: true, cancellation: nil) { entries in
            batches.append(entries)
            return false
        }
        let entries = try #require(batches.first)
        #expect(batches.count == 1)
        let folders = entries.filter(\.isDirectory).map(\.name).sorted()
        #expect(entries.count == 4 && folders == ["folder", "tofolder"])
    }

    /// A listing whose links are not told ends with the caller's flag.
    @Test
    internal func aListingWhoseLinksAreNotToldEndsWithTheFlag() throws {
        let bench = try CovNetSFTPBench(mode: .links)
        try bench.link("xhang", to: ".")
        let session = bench.session()
        defer { session.disconnect() }
        let flag = CancellationFlag()
        let listing = AdoptOutcome { try session.list("/", showHidden: true, cancellation: flag) { _ in true } }
        #expect(Wait.until { bench.requests.contains("17") })
        flag.cancel()
        #expect(listing.ended() && CovNetErrorKind(listing.thrown) == .cancelled)
    }

    /// A listing whose server ends while it is asked about a link fails.
    @Test
    internal func aListingWhoseServerEndsFails() throws {
        let bench = try CovNetSFTPBench(mode: .links)
        try bench.link("xdie", to: ".")
        let session = bench.session()
        defer { session.disconnect() }
        let error = #expect(throws: NetworkError.self) {
            try session.list("/", showHidden: true, cancellation: nil) { _ in true }
        }
        #expect(CovNetErrorKind(error) == .connectionLost)
    }

    /// A listing whose questions about links cannot be sent fails.
    @Test
    internal func aListingWhoseQuestionsCannotBeSentFails() throws {
        let bench = try CovNetSFTPBench(mode: .cutListing)
        try bench.link("tofolder", to: ".")
        let session = bench.session()
        defer { session.disconnect() }
        let error = #expect(throws: NetworkError.self) {
            try session.list("/", showHidden: true, cancellation: nil) { _ in true }
        }
        #expect(CovNetErrorKind(error) == .connectionLost)
    }
}

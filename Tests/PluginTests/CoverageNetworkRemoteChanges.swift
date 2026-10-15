import AFMKernel
import Foundation
import Testing

@testable import NetworkPlugin

/// Changes through the server file system that the server refuses or that cannot be made,
/// and the answers about locations that are not on a server.
@Suite
internal struct CoverageNetworkRemoteChanges {
    private let server = CoverageNetworkMemoryServer()

    /// How often the file system asked the server about `path` by itself.
    private func questions(about path: String) -> Int {
        server.session.calls.filter { $0 == "entry \(path)" }.count
    }

    /// Locations of other schemes and other places are not this file system's.
    @Test
    internal func otherLocationsAreNotThisFileSystems() throws {
        let local = URL(fileURLWithPath: "/tmp")
        let secure = try #require(URL(string: "sftp://memory.invalid/"))
        #expect(throws: FileSystemError.self) { try server.fileSystem.list(secure, showHidden: false) }
        #expect(server.fileSystem.root(of: local) == local)
        #expect(server.fileSystem.displayPath(local) == local.absoluteString)
        #expect(server.fileSystem.volume(of: local) == nil)
        #expect(server.fileSystem.places().isEmpty)
        _ = try server.center.connect(server.key, cancellation: nil)
        #expect(server.fileSystem.places().map(\.url) == [server.url("/")])
    }

    /// A listing the receiver stops, or that is cancelled, is not remembered.
    @Test
    internal func anUnfinishedListingIsNotRemembered() throws {
        try server.fileSystem.list(server.url("/docs"), showHidden: false) { _ in false }
        let flag = CancellationFlag()
        try server.fileSystem.list(server.url("/docs"), showHidden: false, cancellation: flag) { _ in
            flag.cancel()
            return true
        }
        #expect(server.fileSystem.item(at: server.url("/docs/a.txt")) != nil)
        #expect(questions(about: "/docs/a.txt") == 1)
    }

    /// A name that differs only in case from a listed one is asked about before it is written.
    @Test
    internal func aNameAlikeIsAskedAboutBeforeWriting() throws {
        server.session.singleLookupsAreCheap = false
        _ = try server.names("/docs")
        _ = try server.fileSystem.write(server.url("/docs/b.txt"))
        #expect(questions(about: "/docs/b.txt") == 0)
        _ = try server.fileSystem.write(server.url("/docs/A.TXT"))
        #expect(questions(about: "/docs/A.TXT") == 1)
    }

    /// A refused upload makes the folder unknown.
    @Test
    internal func aRefusedUploadMakesTheFolderUnknown() throws {
        _ = try server.names("/docs")
        server.session.failWrites(with: NetworkError.refused(FTPReply(code: 553, lines: ["No"])))
        #expect(throws: NetworkError.self) { try server.fileSystem.write(server.url("/docs/new.txt")) }
        #expect(server.fileSystem.item(at: server.url("/docs/a.txt")) != nil)
        #expect(questions(about: "/docs/a.txt") == 1)
    }

    /// A continued file has its new size in the remembered listing.
    @Test
    internal func aContinuedFileHasItsNewSize() throws {
        _ = try server.names("/docs")
        let writer = try server.fileSystem.append(
            to: server.url("/docs/a.txt"),
            at: 3,
            cancellation: CancellationFlag()
        )
        #expect(server.fileSystem.item(at: server.url("/docs/a.txt"))?.stat.size == 3)
        try writer.write(Data("de".utf8))
        try writer.close(attributes: FileAttributes())
        #expect(server.fileSystem.item(at: server.url("/docs/a.txt"))?.stat.size == 5)
        #expect(questions(about: "/docs/a.txt") == 0)
    }

    /// The root is not removed, a move to another server is no move, and a move onto itself
    /// does nothing.
    @Test
    internal func theRootStaysAndMovesStayOnTheServer() throws {
        #expect(throws: FileSystemError.self) { try server.fileSystem.remove(server.url("/")) }
        let elsewhere = ServerKey(scheme: "ftp", host: "other.invalid").url(path: "/a.txt")
        #expect(throws: FileSystemError.self) {
            try server.fileSystem.move(server.url("/docs/a.txt"), to: elsewhere, replacing: false)
        }
        try server.fileSystem.move(server.url("/docs/a.txt"), to: server.url("/docs/a.txt"), replacing: false)
        #expect(!server.session.calls.contains { $0.hasPrefix("rename") })
    }

    /// A new date is entered into the remembered listing; the root takes attributes too.
    @Test
    internal func aNewDateIsRemembered() throws {
        _ = try server.names("/docs")
        let date = Date(timeIntervalSince1970: 1_000_000)
        try server.fileSystem.setAttributes(FileAttributes(modified: date), of: server.url("/docs/a.txt"))
        #expect(server.fileSystem.item(at: server.url("/docs/a.txt"))?.stat.modified == date)
        try server.fileSystem.setAttributes(FileAttributes(modified: date), of: server.url("/"))
        #expect(server.session.calls.contains("attributes /"))
    }
}

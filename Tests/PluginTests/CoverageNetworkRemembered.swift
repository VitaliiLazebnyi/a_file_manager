import AFMKernel
import Foundation
import Testing

@testable import NetworkPlugin

/// What the server file system remembers of listings: their age, their number, and the changes
/// made while they were read.
@Suite
internal struct CoverageNetworkRemembered {
    private let server = CoverageNetworkMemoryServer()

    /// How often the file system asked the server about `path` by itself.
    private func questions(about path: String) -> Int {
        server.session.calls.filter { $0 == "entry \(path)" }.count
    }

    /// A listing with a name twice keeps the first.
    @Test
    internal func aListingWithANameTwiceKeepsTheFirst() throws {
        server.session.answerLists { path in
            path == "/dup"
                ? .listed([
                    RemoteEntry(name: "a", isDirectory: false, size: 1),
                    RemoteEntry(name: "a", isDirectory: false, size: 2)
                ])
                : .stored
        }
        _ = try server.names("/dup")
        #expect(server.fileSystem.item(at: server.url("/dup/a"))?.stat.size == 1)
        #expect(questions(about: "/dup/a") == 0)
    }

    /// A listing is believed for a few seconds, then the server is asked again.
    @Test
    internal func aListingIsBelievedForAFewSeconds() throws {
        _ = try server.names("/docs")
        #expect(server.fileSystem.item(at: server.url("/docs/a.txt")) != nil)
        #expect(questions(about: "/docs/a.txt") == 0)
        server.clock.advance(by: 11)
        #expect(server.fileSystem.item(at: server.url("/docs/a.txt")) != nil)
        #expect(questions(about: "/docs/a.txt") == 1)
    }

    /// A folder made while its parent was listed is in the remembered listing.
    @Test
    internal func aFolderMadeDuringAListingIsRemembered() throws {
        let (session, fileSystem, url) = (server.session, server.fileSystem, server.url("/docs/new"))
        session.answerLists { path in
            guard path == "/docs", session.calls.filter({ $0 == "list /docs" }).count == 1 else {
                return .stored
            }
            let before = [RemoteEntry(name: "a.txt", isDirectory: false, size: 5)]
            try? fileSystem.createDirectory(at: url)
            return .listed(before)
        }
        _ = try server.names("/docs")
        let asked = questions(about: "/docs/new")
        #expect(server.fileSystem.item(at: url)?.isDirectory == true)
        #expect(questions(about: "/docs/new") == asked)
    }

    /// A listing during which something unknown changed is not remembered.
    @Test
    internal func aListingDuringAnUnknownChangeIsNotRemembered() throws {
        let (session, fileSystem) = (server.session, server.fileSystem)
        let elsewhere = server.url("/docs/unlisted")
        session.answerLists { _ in
            // A change of an entry that is not known makes the folder unknown.
            try? fileSystem.setAttributes(FileAttributes(permissions: 0o600), of: elsewhere)
            return .stored
        }
        _ = try server.names("/docs")
        #expect(server.fileSystem.item(at: server.url("/docs/a.txt")) != nil)
        #expect(questions(about: "/docs/a.txt") == 1)
        // Where one question is dear, the listing is read, and the question is asked all the same.
        session.singleLookupsAreCheap = false
        #expect(server.fileSystem.item(at: server.url("/docs/sub")) != nil)
        #expect(questions(about: "/docs/sub") == 1 && session.calls.contains("list /docs"))
    }

    /// No more than 64 listings are remembered.
    @Test
    internal func noMoreThan64ListingsAreRemembered() throws {
        server.session.answerLists { _ in .listed([]) }
        for index in 0...64 {
            _ = try server.names("/d\(index)")
        }
        #expect(server.fileSystem.item(at: server.url("/d64/x")) == nil)
        #expect(questions(about: "/d64/x") == 0)
        #expect(server.fileSystem.item(at: server.url("/d0/x")) == nil)
        #expect(questions(about: "/d0/x") == 1)
    }

    /// Too many changes during a listing make it unknown; old changes are let go.
    @Test
    internal func tooManyChangesDuringAListingMakeItUnknown() throws {
        let (session, fileSystem) = (server.session, server.fileSystem)
        let urls = (0...1_024).map { server.url("/docs/n\($0)") }
        session.answerLists { path in
            guard path == "/docs", session.calls.filter({ $0 == "list /docs" }).count == 1 else {
                return .stored
            }
            for url in urls {
                try? fileSystem.createDirectory(at: url)
            }
            return .listed([])
        }
        _ = try server.names("/docs")
        #expect(server.fileSystem.item(at: server.url("/docs/a.txt")) != nil)
        #expect(questions(about: "/docs/a.txt") == 1)
        // Changes in many other folders, and much later one more: the old ones are let go, and
        // a listing made afterwards is remembered as it is.
        for index in 0...256 {
            try server.fileSystem.createDirectory(at: server.url("/f\(index)/x"))
        }
        server.clock.advance(by: 301)
        try server.fileSystem.createDirectory(at: server.url("/docs/late"))
        server.clock.advance(by: 1)
        try server.fileSystem.createDirectory(at: server.url("/docs/later"))
        _ = try server.names("/docs")
        #expect(server.fileSystem.item(at: server.url("/docs/late"))?.isDirectory == true)
        #expect(questions(about: "/docs/late") == 1)
    }

    /// A link resolved later changes the remembered entry, and nothing else.
    @Test
    internal func aLinkResolvedLaterChangesTheRememberedEntry() throws {
        server.session.resolveLink("/docs/a.txt", isDirectory: true)
        _ = try server.names("/docs")
        server.session.resolveLink("/", isDirectory: true)
        server.session.resolveLink("/other/x", isDirectory: true)
        server.session.resolveLink("/docs/a.txt", isDirectory: true)
        #expect(server.fileSystem.item(at: server.url("/docs/a.txt"))?.isDirectory == true)
    }
}

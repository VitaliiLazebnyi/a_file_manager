import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FindFilesPlugin

/// Find Files over overlapping roots, with links, and with the cancel.
@Suite
internal struct ToolsAdoptFindFiles {
    /// The file systems of the search.
    internal let fileSystems: FileSystemRegistry
    /// The file system in memory with the tree `/D`.
    internal let memory: MemoryFileSystem

    /// A tree of three levels with a file on each.
    internal init() {
        (fileSystems, memory) = makeFileSystems()
        memory.addFile("/D/top.txt")
        memory.addFile("/D/sub/s.txt")
        memory.addFile("/D/sub/deep/x.txt")
    }

    /// The paths the search finds, in the order they come.
    internal func find(_ query: SearchQuery) -> [String] {
        var found: [String] = []
        FileSearch(query, fileSystems: fileSystems).run { result in found.append(result.url.path) }
        return found
    }

    /// A file listed beside its folder is found once, whatever the depth limit.
    @Test
    internal func aFileListedBesideItsFolderIsFoundOnce() {
        var query = SearchQuery(directory: memory.url("/D"), names: "*.txt")
        query.onlyItems = [
            memory.url("/D"), memory.url("/D/top.txt"), memory.url("/D/sub/s.txt"), memory.url("/D/sub/deep/x.txt")
        ]
        #expect(find(query).sorted() == ["/D/sub/deep/x.txt", "/D/sub/s.txt", "/D/top.txt"])
        // With a limit a deeper file may or may not be reached from the folder; either way once.
        for depth in 0...3 {
            query.maxDepth = depth
            let found = find(query)
            #expect(
                Set(found).count == found.count && found.contains("/D/top.txt") && found.contains("/D/sub/deep/x.txt")
            )
        }
    }

    /// Nested roots, each searched to its own depth, report each file once.
    @Test
    internal func nestedRootsKeptForTheirDepthReportEachFileOnce() throws {
        var query = SearchQuery(directory: memory.url("/D"), names: "*.txt", maxDepth: 1)
        query.moreDirectories = [memory.url("/D/sub")]
        #expect(find(query).sorted() == ["/D/sub/deep/x.txt", "/D/sub/s.txt", "/D/top.txt"])

        // On disk the nested folder may be claimed by the outer root first; the inner root still gets its deeper reach.
        let box = try Sandbox()
        try box.file("top.txt", "t")
        try box.file("sub/s.txt", "s")
        try box.file("sub/deep/x.txt", "x")
        var local = SearchQuery(directory: box.url("."), names: "*.txt", maxDepth: 1)
        local.moreDirectories = [box.url("sub")]
        for _ in 0..<20 {
            let found = find(local).map { URL(fileURLWithPath: $0).lastPathComponent }
            #expect(found.sorted() == ["s.txt", "top.txt", "x.txt"])
        }
    }

    /// A file reached from two overlapping roots is one result.
    @Test
    internal func hardLinkedFilesOfOverlappingRootsAreOneResult() throws {
        let box = try Sandbox()
        try box.file("one/a.txt", "a")
        var query = SearchQuery(directory: box.url("one"), names: "*.txt")
        query.onlyItems = [box.url("one"), box.url("one/a.txt")]
        #expect(find(query).count == 1)
    }

    /// The cancel ends a search that waits on a listing.
    @Test
    internal func cancellingEndsABlockedListing() {
        let probe = ToolsAdopt.ProbingFileSystem(memory)
        let registry = FileSystemRegistry()
        registry.register(probe)
        memory.stallsListings = true
        defer { memory.releaseStalls() }
        let search = FileSearch(SearchQuery(directory: memory.url("/D")), fileSystems: registry)
        let done = ToolsAdopt.background {
            search.run { _ in
                // The search is only to be ended.
            }
        }
        #expect(probe.listing.wait(timeout: .now() + Wait.ceiling) == .success)
        ToolsAdopt.cancelFromThread(search.cancellation)
        #expect(done.wait(timeout: .now() + Wait.ceiling) == .success)
    }

    /// The cancel ends a search for text that waits on a read.
    @Test
    internal func cancellingEndsABlockedContentRead() {
        let probe = ToolsAdopt.ProbingFileSystem(memory)
        let registry = FileSystemRegistry()
        registry.register(probe)
        memory.stallsReads = true
        defer { memory.releaseStalls() }
        let search = FileSearch(SearchQuery(directory: memory.url("/D"), text: "needle"), fileSystems: registry)
        let done = ToolsAdopt.background {
            search.run { _ in
                // The search is only to be ended.
            }
        }
        #expect(probe.reading.wait(timeout: .now() + Wait.ceiling) == .success)
        ToolsAdopt.cancelFromThread(search.cancellation)
        #expect(done.wait(timeout: .now() + Wait.ceiling) == .success)
        #expect(memory.interruptions >= 1)
    }

    /// The cancel ends a search for duplicates that waits on a read, with no groups.
    @Test
    internal func cancellingEndsABlockedDuplicateHash() throws {
        memory.addFile("/E/a", "same")
        memory.addFile("/E/b", "same")
        let probe = ToolsAdopt.ProbingFileSystem(memory)
        let registry = FileSystemRegistry()
        registry.register(probe)
        memory.stallsReads = true
        defer { memory.releaseStalls() }
        let flag = CancellationFlag()
        let items = try ["a", "b"].map { name in try #require(memory.item(at: memory.url("/E/" + name))) }
        let groups = ToolsAdopt.Outcome<[[FileItem]]>()
        let done = ToolsAdopt.background {
            groups.value = DuplicateFinder.groups(
                of: items,
                options: DuplicateOptions(isEnabled: true, sameName: false, sameSize: true, sameContents: true),
                fileSystems: registry,
                cancellation: flag
            )
        }
        #expect(probe.reading.wait(timeout: .now() + Wait.ceiling) == .success)
        ToolsAdopt.cancelFromThread(flag)
        #expect(done.wait(timeout: .now() + Wait.ceiling) == .success)
        #expect(groups.value?.isEmpty == true)
    }

    /// Special items (a device, a pipe) are never read for duplicates.
    @Test
    internal func specialItemsAreNotHashed() throws {
        let special = FileItem(url: memory.url("/D/top.txt"), name: "top.txt", kind: .special, stat: .init(size: 1))
        let plain = try #require(memory.item(at: memory.url("/D/sub/s.txt")))
        let groups = DuplicateFinder.groups(
            of: [special, plain],
            options: DuplicateOptions(isEnabled: true, sameName: false, sameSize: true, sameContents: true),
            fileSystems: fileSystems
        )
        #expect(groups.isEmpty)
    }
}

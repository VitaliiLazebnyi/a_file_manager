import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FindFilesPlugin

/// A search by name, depth and text, on the local disk and on other file systems.
@Suite
internal struct Searching {
    /// The file systems the searches go through: the local disk and `memory`.
    internal let fileSystems: FileSystemRegistry
    /// A file system in memory.
    internal let memory: MemoryFileSystem

    /// The file systems of a test.
    internal init() {
        (fileSystems, memory) = makeFileSystems()
    }

    /// The paths a search finds, relative to its start directory, in the order found.
    internal func find(_ query: SearchQuery) -> [String] {
        var found: [String] = []
        FileSearch(query, fileSystems: fileSystems)
            .run { item in
                found.append(String(item.url.path.dropFirst(query.directory.path.count + 1)))
            }
        return found
    }

    /// A folder with notes, letters, reports in two levels, an ini file and a hidden folder.
    internal func makeTree() throws -> Sandbox {
        let box = try Sandbox()
        try box.file("notes.md", "Meeting with Mr. Smith")
        try box.file("Letter to Mr. Smith.doc", "Dear Sir")
        try box.file("docs/report_01.txt", "quarterly REPORT")
        try box.file("docs/deep/report_02.txt", "nothing here")
        try box.file("docs/win.ini", "k=v")
        try box.file(".hidden/secret.txt", "report")
        return box
    }

    /// A word matches anywhere in a name, a name with a dot whole, and `|` excludes.
    @Test
    internal func searchMasks() {
        #expect(SearchMask("Smith").matches("Letter to Mr. Smith.doc"))
        #expect(!SearchMask(".ini").matches("win.ini"))
        #expect(SearchMask("win.ini").matches("WIN.INI"))
        #expect(SearchMask("*.bak *.old").matches("a.old"))
        #expect(!SearchMask("*.txt | report*").matches("report_01.txt"))
        #expect(SearchMask("").matches("anything"))
    }

    /// Hits come in path order, folders too, and hidden files only when asked for.
    @Test
    internal func findsByNameInPathOrder() throws {
        let box = try makeTree()
        #expect(
            find(SearchQuery(directory: box.root, names: "report")) == [
                "docs/report_01.txt", "docs/deep/report_02.txt"
            ]
        )
        #expect(find(SearchQuery(directory: box.root, names: "smith")) == ["Letter to Mr. Smith.doc"])
        #expect(find(SearchQuery(directory: box.root, names: "docs")) == ["docs"])
        #expect(
            find(SearchQuery(directory: box.root, names: "*.txt", includeHidden: true)).contains(".hidden/secret.txt")
        )
    }

    /// A depth of 0 searches the start directory only, 1 one level below it.
    @Test
    internal func depthLimit() throws {
        let box = try makeTree()
        #expect(find(SearchQuery(directory: box.root, names: "*.txt", maxDepth: 0)).isEmpty)
        #expect(find(SearchQuery(directory: box.root, names: "*.txt", maxDepth: 1)) == ["docs/report_01.txt"])
    }

    /// Text is found without regard to case unless asked, and together with a mask.
    @Test
    internal func findsText() throws {
        let box = try makeTree()
        #expect(find(SearchQuery(directory: box.root, text: "report")) == ["docs/report_01.txt"])
        #expect(find(SearchQuery(directory: box.root, text: "report", caseSensitive: true)).isEmpty)
        #expect(find(SearchQuery(directory: box.root, names: "*.md", text: "smith")) == ["notes.md"])
    }

    /// A text that lies across the border of two blocks of the file is found.
    @Test
    internal func findsTextAcrossBlockBorders() throws {
        let box = try Sandbox()
        try box.file(
            "big.txt",
            String(repeating: "a", count: (1 << 20) - 3) + "needle" + String(repeating: "b", count: 10)
        )
        #expect(find(SearchQuery(directory: box.root, text: "NEEDLE")) == ["big.txt"])
    }

    /// Files tested on all cores are still reported in name order.
    @Test
    internal func textIsSearchedOnAllCoresAndReportedInOrder() throws {
        let box = try Sandbox()
        for index in 0..<200 {
            try box.file(
                String(format: "f%03d.txt", index),
                index.isMultiple(of: 3) ? "has the word treasure in it" : "nothing"
            )
        }
        let expected = stride(from: 0, to: 200, by: 3).map { String(format: "f%03d.txt", $0) }
        #expect(find(SearchQuery(directory: box.root, text: "treasure")) == expected)
    }

    /// A search cancelled before it runs finds nothing.
    @Test
    internal func cancelledSearchFindsNothing() throws {
        let box = try makeTree()
        let search = FileSearch(SearchQuery(directory: box.root), fileSystems: fileSystems)
        search.cancel()
        var count = 0
        search.run { _ in count += 1 }
        #expect(count == 0)
    }

    /// Names and text are found on a file system other than the local disk, folders included.
    @Test
    internal func searchesAnyFileSystem() {
        memory.addFile("/mail/inbox/offer.txt", "special REPORT inside")
        memory.addFile("/mail/inbox/photo.jpg", "binary")
        memory.addFile("/mail/sent/report.txt", "plain")
        memory.addDirectory("/mail/reports")
        #expect(
            find(SearchQuery(directory: memory.url("/mail"), names: "*.txt")) == ["inbox/offer.txt", "sent/report.txt"]
        )
        #expect(find(SearchQuery(directory: memory.url("/mail"), text: "report")) == ["inbox/offer.txt"])
        var kinds: [Bool] = []
        FileSearch(SearchQuery(directory: memory.url("/mail"), names: "report"), fileSystems: fileSystems)
            .run { item in
                kinds.append(item.isDirectory)
            }
        #expect(kinds == [true, false])
    }
}

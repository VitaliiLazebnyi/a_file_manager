import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FindFilesPlugin

@Suite struct Searching {
    let fileSystems: FileSystemRegistry
    let memory: MemoryFileSystem

    init() {
        (fileSystems, memory) = makeFileSystems()
    }

    func find(_ query: SearchQuery) -> [String] {
        var found: [String] = []
        FileSearch(query, fileSystems: fileSystems).run {
            found.append(String($0.url.path.dropFirst(query.directory.path.count + 1)))
        }
        return found
    }

    func makeTree() throws -> Sandbox {
        let box = try Sandbox()
        try box.file("notes.md", "Meeting with Mr. Smith")
        try box.file("Letter to Mr. Smith.doc", "Dear Sir")
        try box.file("docs/report_01.txt", "quarterly REPORT")
        try box.file("docs/deep/report_02.txt", "nothing here")
        try box.file("docs/win.ini", "k=v")
        try box.file(".hidden/secret.txt", "report")
        return box
    }

    @Test func searchMasks() {
        #expect(SearchMask("Smith").matches("Letter to Mr. Smith.doc"))
        #expect(!SearchMask(".ini").matches("win.ini"))
        #expect(SearchMask("win.ini").matches("WIN.INI"))
        #expect(SearchMask("*.bak *.old").matches("a.old"))
        #expect(!SearchMask("*.txt | report*").matches("report_01.txt"))
        #expect(SearchMask("").matches("anything"))
    }

    @Test func findsByNameInPathOrder() throws {
        let box = try makeTree()
        #expect(
            find(SearchQuery(directory: box.root, names: "report")) == [
                "docs/report_01.txt", "docs/deep/report_02.txt"
            ])
        #expect(find(SearchQuery(directory: box.root, names: "smith")) == ["Letter to Mr. Smith.doc"])
        #expect(find(SearchQuery(directory: box.root, names: "docs")) == ["docs"])
        #expect(
            find(SearchQuery(directory: box.root, names: "*.txt", includeHidden: true)).contains(".hidden/secret.txt"))
    }

    @Test func depthLimit() throws {
        let box = try makeTree()
        #expect(find(SearchQuery(directory: box.root, names: "*.txt", maxDepth: 0)).isEmpty)
        #expect(find(SearchQuery(directory: box.root, names: "*.txt", maxDepth: 1)) == ["docs/report_01.txt"])
    }

    @Test func findsText() throws {
        let box = try makeTree()
        #expect(find(SearchQuery(directory: box.root, text: "report")) == ["docs/report_01.txt"])
        #expect(find(SearchQuery(directory: box.root, text: "report", caseSensitive: true)).isEmpty)
        #expect(find(SearchQuery(directory: box.root, names: "*.md", text: "smith")) == ["notes.md"])
    }

    @Test func findsTextAcrossBlockBorders() throws {
        let box = try Sandbox()
        try box.file(
            "big.txt", String(repeating: "a", count: (1 << 20) - 3) + "needle" + String(repeating: "b", count: 10))
        #expect(find(SearchQuery(directory: box.root, text: "NEEDLE")) == ["big.txt"])
    }

    @Test func textIsSearchedOnAllCoresAndReportedInOrder() throws {
        let box = try Sandbox()
        for index in 0..<200 {
            try box.file(
                String(format: "f%03d.txt", index), index % 3 == 0 ? "has the word treasure in it" : "nothing")
        }
        let expected = stride(from: 0, to: 200, by: 3).map { String(format: "f%03d.txt", $0) }
        #expect(find(SearchQuery(directory: box.root, text: "treasure")) == expected)
    }

    @Test func cancelledSearchFindsNothing() throws {
        let box = try makeTree()
        let search = FileSearch(SearchQuery(directory: box.root), fileSystems: fileSystems)
        search.cancel()
        var count = 0
        search.run { _ in count += 1 }
        #expect(count == 0)
    }

    @Test func searchesAnyFileSystem() {
        memory.addFile("/mail/inbox/offer.txt", "special REPORT inside")
        memory.addFile("/mail/inbox/photo.jpg", "binary")
        memory.addFile("/mail/sent/report.txt", "plain")
        memory.addDirectory("/mail/reports")
        #expect(
            find(SearchQuery(directory: memory.url("/mail"), names: "*.txt")) == ["inbox/offer.txt", "sent/report.txt"])
        #expect(find(SearchQuery(directory: memory.url("/mail"), text: "report")) == ["inbox/offer.txt"])
        var kinds: [Bool] = []
        FileSearch(SearchQuery(directory: memory.url("/mail"), names: "report"), fileSystems: fileSystems).run {
            kinds.append($0.isDirectory)
        }
        #expect(kinds == [true, false])
    }
}

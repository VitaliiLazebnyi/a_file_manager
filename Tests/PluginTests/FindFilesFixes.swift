import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FindFilesPlugin

/// Fixes found in review: the walk, special files, files seen twice, the name masks and numbers
/// that used to trap.
@Suite
internal struct FindFilesFixes {
    /// The file systems the searches go through.
    internal let fileSystems: FileSystemRegistry

    /// The file systems of a test.
    internal init() {
        (fileSystems, _) = makeFileSystems()
    }

    /// The paths a search finds, in the order found.
    internal func find(_ query: SearchQuery) -> [String] {
        var found: [String] = []
        FileSearch(query, fileSystems: fileSystems).run { found.append($0.url.path) }
        return found
    }

    /// Runs `work` on another thread and fails instead of hanging if it does not end within `Wait.ceiling`.
    internal func finishes(_ work: @escaping @Sendable () -> Void) -> Bool {
        let seconds = Wait.ceiling
        let done = DispatchSemaphore(value: 0)
        Thread {
            work()
            done.signal()
        }
        .start()
        return done.wait(timeout: .now() + seconds) == .success
    }

    /// Masks match character by character: `[` is a bracket, composed and decomposed letters are one.
    @Test
    internal func masksUseCharactersNotBytesOrBrackets() {
        #expect(SearchMask("file[1].txt").matches("file[1].txt"))
        #expect(!SearchMask("file[1].txt").matches("file1.txt"))
        // Typed composed, named decomposed.
        #expect(SearchMask("caf\u{e9}*").matches("cafe\u{301} au lait.txt"))
        #expect(SearchMask("name.*").matches("name"))
        #expect(SearchMask("name.*").matches("name.txt"))
        #expect(!SearchMask("name.*").matches("names"))
        #expect(SearchMask("a?c.txt").matches("ABC.TXT"))
        #expect(SearchMask("*.*").matches("noextension"))
        #expect(SearchMask("*.txt | draft*").matches("final.txt") && !SearchMask("*.txt | draft*").matches("draft.txt"))
    }

    /// A mask of many stars against a long name ends at once.
    @Test
    internal func aLongWildcardIsNotSlow() {
        let mask = SearchMask(String(repeating: "a*", count: 40) + "b")
        #expect(finishes { _ = mask.matches(String(repeating: "a", count: 5_000)) })
    }

    /// A text search does not open a FIFO or a device, which would never end.
    @Test
    internal func textSearchSkipsPipesAndDevices() throws {
        let box = try Sandbox()
        try box.file("real.txt", "needle")
        #expect(mkfifo(box.url("pipe.txt").path, 0o644) == 0)
        // Written by the other thread before the wait ends, read here after it.
        nonisolated(unsafe) var found: [String] = []
        let ended = finishes {
            FileSearch(SearchQuery(directory: box.root, text: "needle"), fileSystems: fileSystems)
                .run { item in
                    found.append(item.name)
                }
        }
        #expect(ended && found == ["real.txt"])
        #expect(
            FileIdentity.canBeRead(box.url("real.txt")) && !FileIdentity.canBeRead(box.url("pipe.txt"))
                && !FileIdentity.canBeRead(URL(fileURLWithPath: "/dev/zero"))
        )
    }

    /// Duplicates leave out FIFOs, a hard link to a file already found, and roots given twice.
    @Test
    internal func duplicatesIgnorePipesHardLinksAndRepeatedRoots() throws {
        let box = try Sandbox()
        try box.file("a/one.txt", "same bytes")
        try box.file("b/two.txt", "same bytes")
        try box.file("c/other.txt", "different")
        #expect(mkfifo(box.url("c/p1").path, 0o644) == 0 && mkfifo(box.url("c/p2").path, 0o644) == 0)
        try FileManager.default.linkItem(at: box.url("a/one.txt"), to: box.url("a/link.txt"))
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var query = SearchQuery(directory: box.root)
        query.duplicates = DuplicateOptions(isEnabled: true, sameName: false, sameSize: true, sameContents: true)
        // The root twice, and a folder inside it: still every file once.
        query.moreDirectories = [box.root, box.url("a")]
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var groups: [[FileItem]] = []
        #expect(finishes { groups = FileSearch(query, fileSystems: fileSystems).runForDuplicates() })
        #expect(groups.count == 1)
        // The hard link is the same file as one.txt, not a duplicate of it.
        #expect(groups.first.map { Set($0.map(\.name)).count } == 2)
        #expect(groups.first?.filter { ["one.txt", "link.txt"].contains($0.name) }.count == 1)
        #expect(groups.first?.contains { $0.name == "two.txt" } == true)

        var onlyLinks = SearchQuery(directory: box.url("a"))
        onlyLinks.duplicates = query.duplicates
        #expect(FileSearch(onlyLinks, fileSystems: fileSystems).runForDuplicates().isEmpty)
    }

    /// Start directories that lie in each other are searched once, unless a depth limit needs them.
    @Test
    internal func overlappingStartDirectoriesAreSearchedOnce() throws {
        let box = try Sandbox()
        try box.file("docs/a.txt")
        try box.file("docs/sub/b.txt")
        var query = SearchQuery(directory: box.root, names: "*.txt")
        query.moreDirectories = [box.url("docs"), box.url("docs/sub"), box.root]
        #expect(query.directories == [box.root])
        #expect(find(query) == [box.url("docs/a.txt").path, box.url("docs/sub/b.txt").path])
        // With a depth limit an inner folder is not reached from the outer one.
        query.maxDepth = 1
        #expect(query.directories == [box.root, box.url("docs"), box.url("docs/sub")])
        // Two spellings of one folder reach it once as well.
        var twice = SearchQuery(directory: box.url("docs"), names: "*.txt")
        twice.moreDirectories = [URL(fileURLWithPath: box.url("docs").path + "/")]
        #expect(find(twice).count == 2)
    }

    /// A folder reached a second time through a link is not searched again.
    @Test
    internal func aFolderReachedBySymlinkedParentIsNotSearchedTwice() throws {
        let box = try Sandbox()
        try box.file("real/x.txt")
        try FileManager.default.createSymbolicLink(at: box.url("alias"), withDestinationURL: box.url("real"))
        var query = SearchQuery(directory: box.url("real"), names: "x.txt")
        query.moreDirectories = [box.url("alias")]
        #expect(find(query).count == 1)
    }

    /// The hits and folders of many folders come in path order, each folder once.
    @Test
    internal func manyFoldersAreReportedInPathOrder() throws {
        let box = try Sandbox()
        var expected: [String] = []
        for folder in 0..<40 {
            for file in 0..<6 {
                let path = String(format: "d%02d/f%d.txt", folder, file)
                try box.file(path, file.isMultiple(of: 2) ? "has needle" : "nothing")
                if file.isMultiple(of: 2) {
                    expected.append(box.url(path).path)
                }
            }
        }
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var found: [String] = []
        nonisolated(unsafe) var folders: [String] = []
        let search = FileSearch(SearchQuery(directory: box.root, text: "needle"), fileSystems: fileSystems)
        #expect(
            finishes {
                search.run(
                    onDirectory: { folders.append($0.lastPathComponent) },
                    onMatch: { found.append($0.url.path) }
                )
            }
        )
        #expect(found == expected)
        #expect(folders.count == 41 && folders.first == box.root.lastPathComponent)
    }

    /// A cancelled search ends without a hit.
    @Test
    internal func cancelledSearchEndsEarly() throws {
        let box = try Sandbox()
        for folder in 0..<20 { try box.file("d\(folder)/f.txt", "needle") }
        let search = FileSearch(SearchQuery(directory: box.root, text: "needle"), fileSystems: fileSystems)
        search.cancel()
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var count = 0
        #expect(finishes { search.run { _ in count += 1 } })
        #expect(count == 0)
    }

    /// The name mask and the size criterion must both hold.
    @Test
    internal func nameIsTestedBeforeTheCriteria() throws {
        let box = try Sandbox()
        try box.file("keep.log", "12345")
        try box.file("skip.txt", "12345")
        var query = SearchQuery(directory: box.root, names: "*.log")
        query.criteria.size = SizeRule(.greater, 3)
        #expect(find(query) == [box.url("keep.log").path])
    }

    /// Sizes that are too big, negative or not a number are held to what a size can be, not trapped on.
    @Test
    internal func absurdNumbersDoNotTrap() {
        for value in [1e20, -1e20, Double.nan, Double.infinity, 1e300] {
            for comparison in [SizeRule.Comparison.equal, .greater, .less] {
                _ = SizeRule(comparison, value, .gigabytes).matches(1_000)
                _ = SizeRule(comparison, value, .bytes).matches(1_000)
            }
        }
        #expect(SizeRule(.greater, 1e20, .gigabytes).matches(Int64.max) == false)
        #expect(SizeRule(.equal, 2, .kilobytes).matches(2_500))
        #expect(
            SpotlightQuery.string(
                for: {
                    var query = SearchQuery(directory: URL(fileURLWithPath: "/"))
                    query.criteria.size = SizeRule(.equal, .nan, .gigabytes)
                    return query
                }()
            )
            .contains("kMDItemFSSize")
        )
    }

    /// Prepared criteria decide as the criteria do; empty criteria need no preparing.
    @Test
    internal func preparedCriteriaAgreeWithTheDirectOnes() {
        let now = Date()
        var criteria = FileCriteria()
        criteria.notOlderThan = Age(3, .days)
        criteria.size = SizeRule(.greater, 10)
        let fresh = FileItem(
            url: URL(fileURLWithPath: "/a"),
            name: "a",
            stat: .init(size: 20, modified: now.addingTimeInterval(-3_600))
        )
        let old = FileItem(
            url: URL(fileURLWithPath: "/b"),
            name: "b",
            stat: .init(size: 20, modified: now.addingTimeInterval(-86_400 * 30))
        )
        let prepared = criteria.prepared(now: now)
        #expect(prepared?.matches(fresh) == true && prepared?.matches(old) == false)
        #expect(criteria.matches(fresh, now: now) && !criteria.matches(old, now: now))
        #expect(FileCriteria().prepared(now: now) == nil)
    }

    /// A regular expression with `^` and `$` finds a line across small blocks, and only where it is.
    @Test
    internal func regexTextSearchReadsLinesInBlocks() {
        let pattern = try? TextPattern(
            "^beta$",
            caseSensitive: true,
            options: {
                var options = TextSearchOptions()
                options.regex = true
                return options
            }()
        )
        var lines = (0..<20_000).map { "line \($0)" }
        lines.insert("beta", at: 15_000)
        #expect(pattern?.isFound(in: Data(lines.joined(separator: "\n").utf8), blockSize: 4_096) == true)
        #expect(
            pattern?.isFound(in: Data(lines.dropFirst(15_001).joined(separator: "\n").utf8), blockSize: 4_096) == false
        )
    }
}

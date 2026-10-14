import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FindFilesPlugin

/// Fixes found in review: the walk, special files, files seen twice, the name masks and numbers
/// that used to trap.
@Suite struct FindFilesFixes {
    let fileSystems: FileSystemRegistry

    init() {
        (fileSystems, _) = makeFileSystems()
    }

    func find(_ query: SearchQuery) -> [String] {
        var found: [String] = []
        FileSearch(query, fileSystems: fileSystems).run { found.append($0.url.path) }
        return found
    }

    /// Runs `work` on another thread and fails instead of hanging if it does not end.
    func finishes(within seconds: Double = 30, _ work: @escaping () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread {
            work()
            done.signal()
        }.start()
        return done.wait(timeout: .now() + seconds) == .success
    }

    @Test func masksUseCharactersNotBytesOrBrackets() {
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

    @Test func aLongWildcardIsNotSlow() {
        let mask = SearchMask(String(repeating: "a*", count: 40) + "b")
        #expect(finishes { _ = mask.matches(String(repeating: "a", count: 5_000)) })
    }

    @Test func textSearchSkipsPipesAndDevices() throws {
        let box = try Sandbox()
        try box.file("real.txt", "needle")
        #expect(mkfifo(box.url("pipe.txt").path, 0o644) == 0)
        var found: [String] = []
        let ended = finishes {
            FileSearch(SearchQuery(directory: box.root, text: "needle"), fileSystems: fileSystems).run {
                found.append($0.name)
            }
        }
        #expect(ended && found == ["real.txt"])
        #expect(
            FileIdentity.canBeRead(box.url("real.txt")) && !FileIdentity.canBeRead(box.url("pipe.txt"))
                && !FileIdentity.canBeRead(URL(fileURLWithPath: "/dev/zero")))
    }

    @Test func duplicatesIgnorePipesHardLinksAndRepeatedRoots() throws {
        let box = try Sandbox()
        try box.file("a/one.txt", "same bytes")
        try box.file("b/two.txt", "same bytes")
        try box.file("c/other.txt", "different")
        #expect(mkfifo(box.url("c/p1").path, 0o644) == 0 && mkfifo(box.url("c/p2").path, 0o644) == 0)
        try FileManager.default.linkItem(at: box.url("a/one.txt"), to: box.url("a/link.txt"))
        var query = SearchQuery(directory: box.root)
        query.duplicates = DuplicateOptions(isEnabled: true, sameName: false, sameSize: true, sameContents: true)
        // The root twice, and a folder inside it: still every file once.
        query.moreDirectories = [box.root, box.url("a")]
        var groups: [[FileItem]] = []
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

    @Test func overlappingStartDirectoriesAreSearchedOnce() throws {
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

    @Test func aFolderReachedBySymlinkedParentIsNotSearchedTwice() throws {
        let box = try Sandbox()
        try box.file("real/x.txt")
        try FileManager.default.createSymbolicLink(at: box.url("alias"), withDestinationURL: box.url("real"))
        var query = SearchQuery(directory: box.url("real"), names: "x.txt")
        query.moreDirectories = [box.url("alias")]
        #expect(find(query).count == 1)
    }

    @Test func manyFoldersAreReportedInPathOrder() throws {
        let box = try Sandbox()
        var expected: [String] = []
        for folder in 0..<40 {
            for file in 0..<6 {
                let path = String(format: "d%02d/f%d.txt", folder, file)
                try box.file(path, file % 2 == 0 ? "has needle" : "nothing")
                if file % 2 == 0 { expected.append(box.url(path).path) }
            }
        }
        var found: [String] = []
        var folders: [String] = []
        let search = FileSearch(SearchQuery(directory: box.root, text: "needle"), fileSystems: fileSystems)
        #expect(
            finishes {
                search.run(
                    onDirectory: { folders.append($0.lastPathComponent) }, onMatch: { found.append($0.url.path) })
            })
        #expect(found == expected)
        #expect(folders.count == 41 && folders.first == box.root.lastPathComponent)
    }

    @Test func cancelledSearchEndsEarly() throws {
        let box = try Sandbox()
        for folder in 0..<20 { try box.file("d\(folder)/f.txt", "needle") }
        let search = FileSearch(SearchQuery(directory: box.root, text: "needle"), fileSystems: fileSystems)
        search.cancel()
        var count = 0
        #expect(finishes { search.run { _ in count += 1 } })
        #expect(count == 0)
    }

    @Test func nameIsTestedBeforeTheCriteria() throws {
        let box = try Sandbox()
        try box.file("keep.log", "12345")
        try box.file("skip.txt", "12345")
        var query = SearchQuery(directory: box.root, names: "*.log")
        query.criteria.size = SizeRule(.greater, 3)
        #expect(find(query) == [box.url("keep.log").path])
    }

    @Test func absurdNumbersDoNotTrap() {
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
                    var q = SearchQuery(directory: URL(fileURLWithPath: "/"))
                    q.criteria.size = SizeRule(.equal, .nan, .gigabytes)
                    return q
                }()
            ).contains("kMDItemFSSize"))
    }

    @Test func preparedCriteriaAgreeWithTheDirectOnes() {
        let now = Date()
        var criteria = FileCriteria()
        criteria.notOlderThan = Age(3, .days)
        criteria.size = SizeRule(.greater, 10)
        let fresh = FileItem(
            url: URL(fileURLWithPath: "/a"), name: "a", isDirectory: false, size: 20,
            modified: now.addingTimeInterval(-3_600))
        let old = FileItem(
            url: URL(fileURLWithPath: "/b"), name: "b", isDirectory: false, size: 20,
            modified: now.addingTimeInterval(-86_400 * 30))
        let prepared = criteria.prepared(now: now)
        #expect(prepared?.matches(fresh) == true && prepared?.matches(old) == false)
        #expect(criteria.matches(fresh, now: now) && !criteria.matches(old, now: now))
        #expect(FileCriteria().prepared(now: now) == nil)
    }

    @Test func regexTextSearchReadsLinesInBlocks() {
        let pattern = try? TextPattern(
            "^beta$", caseSensitive: true,
            options: {
                var o = TextSearchOptions()
                o.regex = true
                return o
            }())
        var lines = (0..<20_000).map { "line \($0)" }
        lines.insert("beta", at: 15_000)
        #expect(pattern?.isFound(in: Data(lines.joined(separator: "\n").utf8), blockSize: 4_096) == true)
        #expect(
            pattern?.isFound(in: Data(lines.dropFirst(15_001).joined(separator: "\n").utf8), blockSize: 4_096) == false)
    }
}

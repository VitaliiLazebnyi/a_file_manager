import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FindFilesPlugin

/// Round 2 of the review, Find Files: bounded patterns, a walk without races that reports as
/// it goes, the long text, numbers that used to trap, files seen twice.
@Suite struct Review2FindFiles {
    let fileSystems: FileSystemRegistry
    let memory: MemoryFileSystem

    init() {
        (fileSystems, memory) = makeFileSystems()
    }

    /// Runs `work` on another thread and fails instead of hanging if it does not end.
    func finishes(within seconds: Double = 60, _ work: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread {
            work()
            done.signal()
        }.start()
        return done.wait(timeout: .now() + seconds) == .success
    }

    // MARK: Patterns

    @Test func aNameRegexThatBacktracksEndsAndFindsNothing() {
        let mask = SearchMask(#"^(\w+[ _-]?)+\.jpg$"#, regex: true)
        let name = String(repeating: "a", count: 40) + ".png"
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var matched = true
        #expect(finishes { matched = mask.matches(name) })
        #expect(!matched)
        // The expression still does what it says on names it can judge quickly.
        #expect(SearchMask(#"^(\w+[ _-]?)+\.jpg$"#, regex: true).matches("holiday photo.jpg"))
    }

    @Test func aContentRegexThatBacktrackingEndsAndCancels() throws {
        var options = TextSearchOptions()
        options.regex = true
        let pattern = try TextPattern("(a+)+$", caseSensitive: true, options: options)
        let data = Data((String(repeating: "a", count: 60) + "!").utf8)
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var found = true
        #expect(finishes { found = pattern.isFound(in: data) })
        #expect(!found)
        #expect(pattern.trip.hasTimedOut)

        // A cancelled search ends the expression in the middle of a piece.
        let cancellation = CancellationFlag()
        let second = try TextPattern("(a+)+$", caseSensitive: true, options: options)
        Thread {
            Thread.sleep(forTimeInterval: 0.1)
            cancellation.cancel()
        }.start()
        // Written by the other thread before it signals, read here after the wait.
        nonisolated(unsafe) var cancelled: Bool?
        #expect(finishes { cancelled = second.accepts(MemoryReader(data), cancellation: cancellation) })
        #expect(cancelled == false)
    }

    @Test func aFieldRuleRegexIsCheckedAndBounded() {
        var query = SearchQuery(directory: memory.url("/"))
        query.fieldRules = FieldRules(isEnabled: true, rules: [FieldRule("tc.name", .regex, "(")])
        #expect(FileSearch(query, fileSystems: fileSystems).problem as? TextPattern.Problem == .badRegex("("))
        #expect(!FieldRule("tc.name", .regex, "(").isUsable && FieldRule("tc.name", .regex, "a+").isUsable)
        // The rule that is no expression never matches, and its negation always does.
        #expect(!FieldRule("tc.name", .regex, "(").matches("x") && FieldRule("tc.name", .notRegex, "(").matches("x"))

        memory.addFile("/slow/" + String(repeating: "a", count: 50) + "!.txt")
        // Written by the other thread before it signals, read here after the wait.
        nonisolated(unsafe) var slow = SearchQuery(directory: memory.url("/slow"))
        slow.fieldRules = FieldRules(isEnabled: true, rules: [FieldRule("tc.name", .regex, "^(a+)+$")])
        // Written by the other thread before it signals, read here after the wait.
        nonisolated(unsafe) var found = ["not run"]
        #expect(finishes { found = names(of: slow) })
        #expect(found.isEmpty)
    }

    func names(of query: SearchQuery) -> [String] {
        var found: [String] = []
        FileSearch(query, fileSystems: fileSystems).run { found.append($0.name) }
        return found
    }

    @Test func aVeryLongTextIsFoundOnASmallStack() throws {
        // The matcher used to recurse once per character: 6,000 were enough to overflow a thread's stack.
        let text = String(repeating: "ab", count: 10_000)
        for options in [TextSearchOptions(), TextSearchOptions(wholeWords: true)] {
            let pattern = try TextPattern(text, caseSensitive: false, options: options)
            // Written by the other thread before it signals, read here after the wait.
            nonisolated(unsafe) var found = false
            let done = DispatchSemaphore(value: 0)
            let thread = Thread {
                found = pattern.isFound(in: Data(("x " + text.uppercased() + " y").utf8))
                done.signal()
            }
            thread.stackSize = 512 << 10
            thread.start()
            #expect(done.wait(timeout: .now() + 60) == .success && found)
        }
    }

    @Test func utf16WithoutAMarkIsSearchedByRegexInBothByteOrders() throws {
        var options = TextSearchOptions(regex: true, encodings: [.utf16])
        options.regex = true
        let pattern = try TextPattern("wor", caseSensitive: true, options: options)
        #expect(pattern.isFound(in: Data("hello world\n".data(using: .utf16BigEndian)!)))
        #expect(pattern.isFound(in: Data("hello world\n".data(using: .utf16LittleEndian)!)))
        #expect(!pattern.isFound(in: Data("hello there\n".data(using: .utf16BigEndian)!)))
    }

    @Test func aLongLineIsCutBetweenCharacters() throws {
        var options = TextSearchOptions()
        options.regex = true
        let pattern = try TextPattern("é{3}x", caseSensitive: true, options: options)
        // Five megabytes without a line break, in two-byte characters, and the text at the very end.
        let line = String(repeating: "é", count: 2_600_000) + "x"
        #expect(pattern.isFound(in: Data(line.utf8), blockSize: 1 << 20))
        let none = String(repeating: "é", count: 2_600_000)
        #expect(!pattern.isFound(in: Data(none.utf8), blockSize: 1 << 20))
    }

    // MARK: The walk

    @Test func hitsOfAFolderComeBeforeItsLastFilesAreTested() {
        // 70 files; the tests of the last ones wait until the first hits have been reported.
        for index in 0..<70 { memory.addFile(String(format: "/many/f%02d.txt", index)) }
        let release = DispatchSemaphore(value: 0)
        let columns = ColumnRegistry()
        columns.register(
            ContentColumn(id: "gate", title: "Gate") { item in
                if item.name >= "f64" { _ = release.wait(timeout: .now() + 30) }
                return "open"
            })
        var query = SearchQuery(directory: memory.url("/many"))
        query.fieldRules = FieldRules(isEnabled: true, rules: [FieldRule("gate", .equals, "open")])
        let search = FileSearch(query, fileSystems: fileSystems, columns: columns)
        let first = DispatchSemaphore(value: 0)
        // Counted by the thread that searches and read by the one that waits: under a lock.
        let lock = NSLock()
        // Guarded by `lock`.
        nonisolated(unsafe) var hits = 0
        let thread = Thread {
            search.run { _ in
                let isFirst = lock.withLock { () -> Bool in
                    hits += 1
                    return hits == 1
                }
                if isFirst { first.signal() }
            }
        }
        thread.start()
        // The first hit arrives while the last files are still held back.
        let early = first.wait(timeout: .now() + 30) == .success
        for _ in 0..<8 { release.signal() }
        #expect(early)
        #expect(finishes(within: 600) { while lock.withLock({ hits }) < 70 { Thread.sleep(forTimeInterval: 0.01) } })
    }

    @Test func aSlowFrontJobDoesNotLetTheOthersListTheWholeTree() {
        for folder in 0..<200 {
            for file in 0..<10 { memory.addFile(String(format: "/wide/d%03d/f%d.txt", folder, file)) }
        }
        let release = DispatchSemaphore(value: 0)
        let columns = ColumnRegistry()
        columns.register(
            ContentColumn(id: "gate", title: "Gate") { item in
                if item.url.path == "/wide/d000/f0.txt" { _ = release.wait(timeout: .now() + 60) }
                return "open"
            })
        var query = SearchQuery(directory: memory.url("/wide"))
        query.fieldRules = FieldRules(isEnabled: true, rules: [FieldRule("gate", .equals, "open")])
        let search = FileSearch(query, fileSystems: fileSystems, columns: columns, tuning: .init(budget: 30))
        // Written by the other thread before it signals, read here after the wait.
        nonisolated(unsafe) var count = 0
        let done = DispatchSemaphore(value: 0)
        Thread {
            search.run { _ in count += 1 }
            done.signal()
        }.start()
        // While the first folder's test is held, the other threads read a few folders ahead and then wait.
        Thread.sleep(forTimeInterval: 1)
        let listed = memory.listRequests.filter { $0.hasPrefix("/wide/d") }.count
        #expect(listed < 100)
        release.signal()
        // The 2,000 files and the 200 folders.
        #expect(done.wait(timeout: .now() + 60) == .success && count == 2_200)
    }

    @Test func cancellingAContentSearchWhileItRunsIsSafe() {
        for folder in 0..<12 {
            for file in 0..<40 {
                memory.addFile("/tree/d\(folder)/f\(file).txt", String(repeating: "lorem ipsum ", count: 50))
            }
        }
        for round in 0..<20 {
            var query = SearchQuery(directory: memory.url("/tree"), text: "needle-\(round)")
            query.fieldRules = FieldRules(isEnabled: true, rules: [FieldRule("tc.size", .greater, "1")])
            let search = FileSearch(query, fileSystems: fileSystems)
            Thread {
                Thread.sleep(forTimeInterval: Double(round) / 2_000)
                search.cancel()
            }.start()
            #expect(finishes { search.run { _ in } })
        }
    }

    @Test func aWalkThatIsClosedDoesNotComeBackToLife() {
        for index in 0..<30 { memory.addFile("/deep/a/b/c/d\(index)/e.txt", "x") }
        var query = SearchQuery(directory: memory.url("/deep"))
        query.resultLimit = 5
        let search = FileSearch(query, fileSystems: fileSystems)
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var found = 0
        #expect(finishes { search.run { _ in found += 1 } })
        #expect(found == 5 && search.reachedResultLimit)
        var all = SearchQuery(directory: memory.url("/deep"))
        all.resultLimit = 1_000
        let complete = FileSearch(all, fileSystems: fileSystems)
        var every = 0
        complete.run { _ in every += 1 }
        #expect(every > 30 && !complete.reachedResultLimit)
    }

    @Test func searchInFoundFilesDoesNotCompareEveryItemWithEveryFolder() {
        for folder in 0..<300 { for file in 0..<10 { memory.addFile("/found/d\(folder)/n\(file).txt") } }
        var items: [URL] = []
        for folder in 0..<300 {
            items.append(memory.url("/found/d\(folder)"))
            for file in 0..<10 { items.append(memory.url("/found/d\(folder)/n\(file).txt")) }
        }
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var query = SearchQuery(directory: memory.url("/found"), names: "n1.txt")
        query.onlyItems = items
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var hits: [String] = []
        #expect(finishes { hits = names(of: query) })
        // A file listed beside the folder that holds it is found once, by the folder.
        #expect(hits.count == 300)
    }

    // MARK: Files seen twice, special files

    @Test func theSameRemotePlaceWrittenTwoWaysIsNotADuplicateOfItself() {
        func item(_ text: String) -> FileItem {
            FileItem(
                url: URL(string: text)!, name: "same.txt", isDirectory: false, size: 5,
                modified: Date(timeIntervalSince1970: 1))
        }
        let options = DuplicateOptions(isEnabled: true, sameName: true, sameSize: true, sameContents: false)
        let twice = DuplicateFinder.groups(
            of: [item("sftp://HOST/a/same.txt"), item("sftp://host/a/same.txt")], options: options,
            fileSystems: fileSystems)
        #expect(twice.isEmpty)
        // Two different files of one name are still a group.
        let two = DuplicateFinder.groups(
            of: [item("sftp://host/a/same.txt"), item("sftp://host/b/same.txt")], options: options,
            fileSystems: fileSystems)
        #expect(two.count == 1 && two[0].count == 2)
    }

    @Test func overlappingRootsKeepHardLinksAndDropTheSameFolder() throws {
        let box = try Sandbox()
        try box.file("dir/one.txt", "x")
        try FileManager.default.linkItem(at: box.url("dir/one.txt"), to: box.url("dir/two.txt"))
        var query = SearchQuery(directory: box.url("dir"))
        query.moreDirectories = [box.url("dir"), box.url("dir/one.txt")]
        query.onlyItems = [box.url("dir/one.txt"), box.url("dir/two.txt"), box.url("dir/one.txt")]
        let found = names(of: query)
        #expect(found.sorted() == ["one.txt", "two.txt"])
    }

    @Test func aFifoOrAStubIsNotOpenedForReading() throws {
        let box = try Sandbox()
        try box.file("real.txt", "needle")
        #expect(mkfifo(box.url("pipe").path, 0o644) == 0)
        let reader = try #require(LocalFileReader.open(box.url("real.txt")))
        #expect(try reader.read(upToCount: 100) == Data("needle".utf8))
        #expect(try reader.read(upToCount: 100) == nil)
        reader.close()
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var opened: (any FileReader)?
        #expect(finishes { opened = LocalFileReader.open(box.url("pipe")) })
        #expect(opened == nil)
        #expect(LocalFileReader.open(box.url("missing")) == nil)
        #expect(FileIdentity.datalessFlag == UInt32(SF_DATALESS))
    }

    // MARK: Numbers that used to trap

    @Test func absurdNumbersAreHeldToWhatTheyCanBe() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for unit in Age.Unit.allCases {
            for count in [Int.max, Int.min, -1, 0, 1 << 62] {
                _ = Age(count, unit).cutoff(before: now)
            }
        }
        #expect(Age(Int.max, .weeks).cutoff(before: now) < now)
        #expect(Age(-5, .days).cutoff(before: now) == Calendar.current.startOfDay(for: now))
        var settings = SearchSettings()
        settings.depth = -4
        let query = settings.query(relativeTo: memory.url("/"), fileSystems: fileSystems, includeHidden: false)
        #expect(query.maxDepth == 0)
        settings.depth = Int.max
        #expect(
            settings.query(relativeTo: memory.url("/"), fileSystems: fileSystems, includeHidden: false).maxDepth
                == Int.max)
        #expect(SizeRule(.greater, .infinity, .gigabytes).bytes == Int64.max && SizeRule(.less, .nan).bytes == 0)
    }

    // MARK: Spotlight

    @Test func spotlightReChecksWhatTheIndexCannotJudge() {
        var query = SearchQuery(directory: memory.url("/"), text: "smith")
        #expect(SpotlightQuery.handlesText(of: query) && !SpotlightQuery.recheckingText(of: query))
        query.caseSensitive = true
        #expect(SpotlightQuery.recheckingText(of: query))
        query.caseSensitive = false
        query.text = "john smith"
        #expect(SpotlightQuery.recheckingText(of: query))
        query.text = "smith"
        query.textOptions.encodings = [.utf8, .western]
        #expect(SpotlightQuery.recheckingText(of: query))
    }
}

/// A reader over bytes in memory.
/// Unchecked: used by one thread at a time, as the protocol allows.
private final class MemoryReader: FileReader, @unchecked Sendable {
    private let data: Data
    private var position = 0

    init(_ data: Data) { self.data = data }

    func read(upToCount count: Int) -> Data? {
        guard position < data.count else { return nil }
        let end = min(position + count, data.count)
        defer { position = end }
        return data.subdata(in: position..<end)
    }

    func seek(to offset: UInt64) { position = min(Int(offset), data.count) }
    func close() {}
    func interrupt() {}
}

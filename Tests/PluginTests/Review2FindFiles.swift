import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FindFilesPlugin

/// Round 2 of the review, Find Files: bounded patterns, a walk without races that reports as
/// it goes, the long text, numbers that used to trap, files seen twice.
@Suite
internal struct Review2FindFiles {
    /// A reader over bytes in memory.
    ///
    /// Unchecked: used by one thread at a time, as the protocol allows.
    private final class MemoryReader: FileReader, @unchecked Sendable {
        private let data: Data
        private var position = 0

        init(_ data: Data) { self.data = data }

        func read(upToCount count: Int) -> Data? {
            guard position < data.count else {
                return nil
            }
            let end = min(position + count, data.count)
            defer { position = end }
            return data.subdata(in: position..<end)
        }

        func seek(to offset: UInt64) { position = min(Int(offset), data.count) }

        func close() {
            // Nothing to close.
        }

        func interrupt() {
            // Nothing waits that could be woken.
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The file systems the searches go through: the local disk and `memory`.
    internal let fileSystems: FileSystemRegistry
    /// A file system in memory.
    internal let memory: MemoryFileSystem

    /// The file systems of a test.
    internal init() {
        (fileSystems, memory) = makeFileSystems()
    }

    /// Runs `work` on another thread and fails instead of hanging if it does not end within `Wait.ceiling`.
    internal func finishes(_ work: @escaping @Sendable () -> Void) -> Bool {
        finishes(within: Wait.ceiling, work)
    }

    /// Runs `work` on another thread and fails instead of hanging if it does not end within `seconds`.
    internal func finishes(within seconds: Double, _ work: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread {
            work()
            done.signal()
        }
        .start()
        return done.wait(timeout: .now() + seconds) == .success
    }

    // MARK: Patterns

    /// A name expression that backtracks without end is stopped and matches nothing; quick names still match.
    @Test
    internal func aNameRegexThatBacktracksEndsAndFindsNothing() {
        let mask = SearchMask(#"^(\w+[ _-]?)+\.jpg$"#, regex: true)
        let name = String(repeating: "a", count: 40) + ".png"
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var matched = true
        #expect(finishes { matched = mask.matches(name) })
        #expect(!matched)
        // The expression still does what it says on names it can judge quickly.
        #expect(SearchMask(#"^(\w+[ _-]?)+\.jpg$"#, regex: true).matches("holiday photo.jpg"))
    }

    /// A text expression that backtracks without end is stopped and says so; a cancelled search ends it too.
    @Test
    internal func aContentRegexThatBacktrackingEndsAndCancels() throws {
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
        }
        .start()
        // Written by the other thread before it signals, read here after the wait.
        nonisolated(unsafe) var accepted = true
        #expect(finishes { accepted = second.accepts(MemoryReader(data), cancellation: cancellation) })
        #expect(!accepted)
    }

    /// A rule whose expression is broken stops the search before it starts; a slow one matches nothing.
    @Test
    internal func aFieldRuleRegexIsCheckedAndBounded() {
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

    /// The names a search finds, in the order found.
    internal func names(of query: SearchQuery) -> [String] {
        var found: [String] = []
        FileSearch(query, fileSystems: fileSystems).run { found.append($0.name) }
        return found
    }

    /// A text of 20,000 characters is found on a thread with a small stack, also as whole words.
    @Test
    internal func aVeryLongTextIsFoundOnASmallStack() throws {
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
            #expect(done.wait(timeout: .now() + Wait.ceiling) == .success && found)
        }
    }

    /// UTF-16 without a byte order mark is searched by an expression in either byte order.
    @Test
    internal func utf16WithoutAMarkIsSearchedByRegexInBothByteOrders() throws {
        var options = TextSearchOptions(regex: true, encodings: [.utf16])
        options.regex = true
        let pattern = try TextPattern("wor", caseSensitive: true, options: options)
        #expect(pattern.isFound(in: try #require("hello world\n".data(using: .utf16BigEndian))))
        #expect(pattern.isFound(in: try #require("hello world\n".data(using: .utf16LittleEndian))))
        #expect(!pattern.isFound(in: try #require("hello there\n".data(using: .utf16BigEndian))))
    }

    /// A line of five megabytes is cut between characters, and a text at its very end is found.
    @Test
    internal func aLongLineIsCutBetweenCharacters() throws {
        var options = TextSearchOptions()
        options.regex = true
        let pattern = try TextPattern("é{3}x", caseSensitive: true, options: options)
        // Five megabytes without a line break, in two-byte characters, and the text at the very end.
        let line = String(repeating: "é", count: 2_600_000) + "x"
        #expect(pattern.isFound(in: Data(line.utf8), blockSize: 1 << 20))
        let none = String(repeating: "é", count: 2_600_000)
        #expect(!pattern.isFound(in: Data(none.utf8), blockSize: 1 << 20))
    }

    // MARK: Files seen twice, special files

    /// One remote place written in two ways is no duplicate of itself; two files of one name are.
    @Test
    internal func theSameRemotePlaceWrittenTwoWaysIsNotADuplicateOfItself() throws {
        func item(_ text: String) throws -> FileItem {
            FileItem(
                url: try #require(URL(string: text)),
                name: "same.txt",
                stat: .init(size: 5, modified: Date(timeIntervalSince1970: 1))
            )
        }
        let options = DuplicateOptions(isEnabled: true, sameName: true, sameSize: true, sameContents: false)
        let twice = DuplicateFinder.groups(
            of: [try item("sftp://HOST/a/same.txt"), try item("sftp://host/a/same.txt")],
            options: options,
            fileSystems: fileSystems
        )
        #expect(twice.isEmpty)
        // Two different files of one name are still a group.
        let two = DuplicateFinder.groups(
            of: [try item("sftp://host/a/same.txt"), try item("sftp://host/b/same.txt")],
            options: options,
            fileSystems: fileSystems
        )
        #expect(two.count == 1 && two[0].count == 2)
    }

    /// Overlapping roots report a file once, while two hard links in one folder are two files.
    @Test
    internal func overlappingRootsKeepHardLinksAndDropTheSameFolder() throws {
        let box = try Sandbox()
        try box.file("dir/one.txt", "x")
        try FileManager.default.linkItem(at: box.url("dir/one.txt"), to: box.url("dir/two.txt"))
        var query = SearchQuery(directory: box.url("dir"))
        query.moreDirectories = [box.url("dir"), box.url("dir/one.txt")]
        query.scope = .only([box.url("dir/one.txt"), box.url("dir/two.txt"), box.url("dir/one.txt")])
        let found = names(of: query)
        #expect(found.sorted() == ["one.txt", "two.txt"])
    }

    /// A local file is read through a checked descriptor; a FIFO or a missing file gives no reader.
    @Test
    internal func aFifoOrAStubIsNotOpenedForReading() throws {
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

    /// Ages, depths and sizes beyond reason are held to what they can be.
    @Test
    internal func absurdNumbersAreHeldToWhatTheyCanBe() {
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
                == Int.max
        )
        #expect(SizeRule(.greater, .infinity, .gigabytes).bytes == Int64.max && SizeRule(.less, .nan).bytes == 0)
    }

    // MARK: Spotlight

    /// Files the index returns are read for the text where it cannot judge case, phrases or encodings.
    @Test
    internal func spotlightReChecksWhatTheIndexCannotJudge() {
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

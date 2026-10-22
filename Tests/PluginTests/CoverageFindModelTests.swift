import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FindFilesPlugin

/// The parts of Find Files below the window at their edges: masks, criteria, text patterns,
/// readers that fail, duplicates on shares and searches that are cancelled.
@Suite
internal struct CoverageFindModel {
    internal let box: Sandbox
    internal let memory = MemoryFileSystem()
    internal let registry = FileSystemRegistry()

    internal init() throws {
        box = try Sandbox()
        registry.register(LocalFileSystem())
        registry.register(memory)
    }

    // MARK: Masks and criteria

    @Test
    internal func aBrokenExpressionMatchesNoName() {
        #expect(!SearchMask("(", regex: true).matches("x"))
    }

    @Test
    internal func aMaskEndingInADotMatchesANameWithoutExtension() {
        #expect(SearchMask("readme.").matches("readme") && !SearchMask("readme.").matches("readme.txt"))
        #expect(SearchMask("read*.*").matches("readme"))
    }

    @Test
    internal func anAgeBeyondTheCalendarReachesBackForever() {
        // The Chinese calendar does not count a million years back.
        let chinese = Calendar(identifier: .chinese)
        #expect(Age(Int.max, .years).cutoff(before: Date(), calendar: chinese) == .distantPast)
    }

    @Test
    internal func aSizeInBytesEndsOneByteLater() {
        #expect(SizeRule(.equal, 10).upperBytes == 11 && SizeRule(.equal, 2, .kilobytes).upperBytes == 3_072)
    }

    @Test
    internal func theBuiltInFieldsShowPathDateAndPermissions() throws {
        let item = FileItem(url: memory.addFile("/f/a.txt", "abc"), name: "a.txt")
        let fields = Dictionary(uniqueKeysWithValues: SearchField.builtIn(fileSystems: registry).map { ($0.id, $0) })
        #expect(try #require(fields["tc.path"]).value(item) == registry.displayPath(memory.url("/f/")))
        #expect(try #require(fields["tc.date"]).value(item) == Format.date(item.modified))
        #expect(try #require(fields["tc.attr"]).value(item) == Format.permissions(item.permissions))
    }

    @Test
    internal func aColumnOfTheSameNameAsABuiltInFieldGivesWay() {
        let columns = ColumnRegistry()
        columns.register(ContentColumn(id: "tc.name", title: "Other") { _ in "other" })
        var query = SearchQuery(directory: memory.url("/"))
        query.fieldRules = FieldRules(isEnabled: true, rules: [FieldRule("tc.name", .equals, "a.txt")])
        let search = FileSearch(query, fileSystems: registry, columns: columns)
        #expect(search.accepts(FileItem(url: memory.addFile("/a.txt"), name: "a.txt")))
    }

    @Test
    internal func aRegexRuleIsMatchedAsAnExpression() {
        #expect(FieldRule("tc.name", .regex, "^a.c$").matches("abc"))
        // One that takes too long for the text matches nothing.
        #expect(!FieldRule("tc.name", .regex, "(a*)*b").matches(String(repeating: "a", count: 40)))
    }

    @Test
    internal func anyRuleMayMatchWhenAskedSo() {
        let rules = FieldRules(
            isEnabled: true,
            matchAll: false,
            rules: [FieldRule("tc.name", .contains, "zz"), FieldRule("tc.name", .contains, "a")]
        )
        .prepared()
        let item = FileItem(url: memory.addFile("/any/a.txt"), name: "a.txt")
        let fields = Dictionary(uniqueKeysWithValues: SearchField.builtIn(fileSystems: registry).map { ($0.id, $0) })
        #expect(rules.matches(item, fields: fields))
    }

    @Test
    internal func aNameTheExpressionTakesTooLongForIsNoHit() {
        var query = SearchQuery(directory: memory.url("/"), names: "(a*)*b")
        query.namesAreRegex = true
        let search = FileSearch(query, fileSystems: registry)
        let name = String(repeating: "a", count: 40)
        #expect(!search.accepts(FileItem(url: memory.addFile("/slow/" + name), name: name)))
        #expect(search.regexTimedOut)
    }

    @Test
    internal func cancelledRulesMatchNothing() {
        let rules = FieldRules(isEnabled: true, rules: [FieldRule("tc.name", .contains, "a")]).prepared()
        let item = FileItem(url: memory.addFile("/a.txt"), name: "a.txt")
        let fields = Dictionary(uniqueKeysWithValues: SearchField.builtIn(fileSystems: registry).map { ($0.id, $0) })
        #expect(rules.matches(item, fields: fields) && !rules.matches(item, fields: fields, cancelled: { true }))
    }

    // MARK: Regular expressions

    @Test
    internal func anEmptyTextIsMatchedAsIs() throws {
        let empty = try NSRegularExpression(pattern: "^$")
        #expect(FindRegex.firstMatch(empty, in: "", cancelled: { false }) == .matched)
        #expect(FindRegex.firstMatch(try NSRegularExpression(pattern: "a"), in: "", cancelled: { false }) == .unmatched)
    }

    @Test
    internal func aTrippedExpressionIsNotTriedAgain() throws {
        let trip = RegexTrip(limit: 1)
        trip.recordTimeout()
        #expect(!FindRegex.matches(try NSRegularExpression(pattern: "a"), in: "a", trip: trip, cancelled: { false }))
    }

    // MARK: Text patterns

    @Test
    internal func problemsSayWhatIsWrong() {
        #expect(TextPattern.Problem.emptyText.errorDescription == "There is no text to find.")
        #expect(TextPattern.Problem.badRegex("x").errorDescription == "The regular expression cannot be used: x")
        #expect(
            TextPattern.Problem.notRepresentable("€").errorDescription
                == "\"€\" cannot be written in any of the chosen encodings."
        )
        #expect(TextEncoding.utf16.stringEncoding == .utf16LittleEndian)
    }

    @Test
    internal func noEncodingChosenMeansUTF8AndRepeatedNeedlesAreOne() throws {
        var options = TextSearchOptions()
        options.encodings = []
        #expect(try TextPattern("abc", options: options).isFound(in: Data("xabcx".utf8)))
        options.encodings = [.utf8, .western]
        #expect(try TextPattern("abc", options: options).isFound(in: Data("xabcx".utf8)))
    }

    @Test
    internal func aTrailingBackslashStays() {
        #expect(TextPattern.unescape("a\\") == "a\\" && TextPattern.unescape("a\\q") == "a\\q")
    }

    @Test
    internal func hexDigitsMustComeInPairs() {
        var options = TextSearchOptions()
        options.hex = true
        #expect(throws: TextPattern.Problem.badHex("0\"A\"")) { try TextPattern("0\"A\"", options: options) }
        #expect(throws: TextPattern.Problem.badHex("0 1")) { try TextPattern("0 1", options: options) }
    }

    @Test
    internal func aWholeWordThatGoesOnIsNoHit() throws {
        var options = TextSearchOptions()
        options.wholeWords = true
        #expect(try !TextPattern("ab", options: options).isFound(in: Data("abc".utf8)))
        // Upper and lower case both count, and a long s is written in two bytes or as an S in one:
        // the longer way runs off the end of the file, the shorter one is found.
        #expect(try TextPattern("a\u{17F}").isFound(in: Data("xaS".utf8)))
    }

    @Test
    internal func aCancelledSearchFindsNothing() throws {
        let cancellation = CancellationFlag()
        cancellation.cancel()
        let reader = TextPattern.DataReader(Data("abc".utf8))
        #expect(try !TextPattern("b").isFound(in: reader, cancellation: cancellation))
        var options = TextSearchOptions()
        options.regex = true
        let regexReader = TextPattern.DataReader(Data("abc".utf8))
        #expect(try !TextPattern("b", options: options).isFound(in: regexReader, cancellation: cancellation))
    }

    @Test
    internal func aReaderThatFailsFindsNothing() throws {
        #expect(try !TextPattern("b").isFound(in: FailingReader()))
        var options = TextSearchOptions()
        options.regex = true
        #expect(try !TextPattern("b", options: options).isFound(in: FailingReader()))
        // NOT containing: a file that cannot be read never passes.
        options = TextSearchOptions()
        options.notContaining = true
        #expect(try !TextPattern("b", options: options).accepts(FailingReader()))
    }

    @Test
    internal func aTrippedExpressionGivesUpOnTheFile() throws {
        var options = TextSearchOptions()
        options.regex = true
        let pattern = try TextPattern("(a*)*b", options: options)
        // Every piece takes the expression too long: after three files it is not tried again.
        let long = Data((String(repeating: "a", count: 40) + "\n").utf8)
        for _ in 0..<4 { #expect(!pattern.isFound(in: long)) }
        #expect(!pattern.accepts(TextPattern.DataReader(long)))
    }

    @Test
    internal func longLinesAreCutBetweenCharacters() throws {
        var options = TextSearchOptions()
        options.regex = true
        let longest = 4 << 20
        for tail in ["\u{1F600}", "\u{20AC}", "\u{E9}", "a"] {
            // A line longer than the longest, ending in the middle of its last character.
            var data = Data(repeating: 0x61, count: longest)
            let bytes = Array(tail.utf8)
            data.append(contentsOf: bytes.count > 1 ? bytes.dropLast() : bytes)
            #expect(try TextPattern(".", options: options).isFound(in: data, blockSize: longest + 8))
        }
        options.encodings = [.utf16]
        let wide = Data(repeating: 0x61, count: longest + 8)
        #expect(try TextPattern(".", options: options).isFound(in: wide, blockSize: longest + 16))
        // A byte the Western code page does not have is read as Latin-1. It comes first: an
        // expression that has to go through the 4 MB of a piece before it finds anything may
        // use up the time a piece is given (in a build for the thread sanitizer, with other
        // tests running, it did) and then counts as not found.
        options.encodings = [.western]
        var western = Data([0x81])
        western.append(Data(repeating: 0x61, count: longest + 8))
        #expect(try TextPattern("\\x81", options: options).isFound(in: western, blockSize: longest + 16))
    }

    @Test
    internal func anEmptyFileHoldsNoText() throws {
        #expect(try !TextPattern("a").isFound(in: Data()))
    }

    @Test
    internal func theDataReaderSeeksAndCloses() {
        let reader = TextPattern.DataReader(Data("abcdef".utf8))
        reader.seek(to: 4)
        #expect(reader.read(upToCount: 10) == Data("ef".utf8))
        reader.seek(to: 99)
        #expect(reader.read(upToCount: 10) == nil)
        reader.close()
    }

    // MARK: The local reader

    @Test
    internal func aLocalReaderOnlyReadsPlainFilesHere() throws {
        #expect(LocalFileReader.open(memory.url("/a")) == nil)
        #expect(FileIdentity.canBeRead(memory.url("/a")) && !FileIdentity.canBeRead(box.url("gone")))
        let file = try box.file("a.txt", "abcdef")
        let reader = try #require(LocalFileReader.open(file))
        #expect(try reader.read(upToCount: 0) == nil)
        try reader.seek(to: 2)
        #expect(try reader.read(upToCount: 2) == Data("cd".utf8))
        reader.interrupt()
        #expect(throws: CocoaError.self) { try reader.seek(to: UInt64.max) }
        reader.close()
        #expect(throws: CocoaError.self) { try reader.read(upToCount: 1) }
        #expect(throws: CocoaError.self) { try reader.seek(to: 0) }
    }

    @Test
    internal func anInterruptedReadIsTriedAgainAndAFailedOneReported() throws {
        let file = try box.file("b.txt", "abc")
        let calls = Calls()
        let interrupted = try #require(
            LocalFileReader.open(file) { descriptor, buffer, count in
                guard calls.next() > 1 else {
                    errno = EINTR
                    return -1
                }
                return Darwin.read(descriptor, buffer, count)
            }
        )
        #expect(try interrupted.read(upToCount: 10) == Data("abc".utf8))
        let failing = try #require(
            LocalFileReader.open(file) { _, _, _ in
                errno = EIO
                return -1
            }
        )
        #expect(throws: POSIXError.self) { try failing.read(upToCount: 10) }
        let unknown = try #require(
            LocalFileReader.open(file) { _, _, _ in
                errno = 9_999
                return -1
            }
        )
        #expect(throws: POSIXError(.EIO)) { try unknown.read(upToCount: 10) }
    }

    // MARK: Duplicates

    @Test
    internal func aShareIsToldByItsSourceAndThePathInIt() throws {
        let mount = DuplicateFinder.Mount(from: "smbfs://host/share", on: "/Volumes/share")
        #expect(mount.place(of: "/Volumes/share/a/b.txt") == "smbfs://host/share/a/b.txt")
        #expect(mount.place(of: "/elsewhere/c.txt") == "smbfs://host/share/elsewhere/c.txt")
        #expect(DuplicateFinder.Mount(from: "s", on: "/").place(of: "x") == "s/x")
        // The home folders of the system are mounted by the automounter, not from a local disk.
        let home = try #require(DuplicateFinder.Mount.of(URL(fileURLWithPath: "/System/Volumes/Data/home")))
        #expect(home.on == "/System/Volumes/Data/home" && home.from.hasPrefix("autofs:"))
        #expect(DuplicateFinder.Mount.of(box.root) == nil)
    }

    /// One share mounted at two places: the same file in it is one file.
    @Test
    internal func theSameFileOfAShareMountedTwiceIsOne() throws {
        // Two files on two volumes: the shared cache of the system lies on a volume of its own.
        let local = try box.file("one/dyld_shared_cache_arm64e", "x")
        let system = URL(
            fileURLWithPath: "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e"
        )
        let items = [local, system].map { FileItem(url: $0, name: $0.lastPathComponent) }
        let kept = DuplicateFinder.distinctFiles(items.map { (key: 0, item: $0) }) { url in
            DuplicateFinder.Mount(from: "share", on: url.deletingLastPathComponent().path)
        }
        #expect(kept.map(\.item.url) == [local])
    }

    @Test
    internal func aLocalFileThatIsGoneIsLeftOut() throws {
        let here = try box.file("here.txt", "same")
        let items = [here, box.url("gone.txt")].map { FileItem(url: $0, name: $0.lastPathComponent) }
        #expect(DuplicateFinder.distinctFiles(items.map { (key: 0, item: $0) }).map(\.item.url) == [here])
    }

    @Test
    internal func aDigestCancelledWhileReadingIsNone() {
        let cancellation = CancellationFlag()
        let reads = CancellingFileSystem(cancellation: cancellation)
        let files = FileSystemRegistry()
        files.register(reads)
        let url = reads.base.addFile("/big.bin", String(repeating: "x", count: 10))
        #expect(DuplicateFinder.digest(of: url, fileSystems: files, cancellation: cancellation) == nil)
    }

    // MARK: Searches

    @Test
    internal func aSearchOfChosenItemsThatIsCancelledFindsNothing() {
        let file = memory.addFile("/c/a.txt")
        var query = SearchQuery(directory: memory.url("/c"))
        query.onlyItems = [file, memory.url("/c")]
        let search = FileSearch(query, fileSystems: registry)
        search.cancel()
        var found: [FileItem] = []
        search.run { found.append($0) }
        #expect(found.isEmpty)
    }

    /// A folder whose listing breaks off after its entries came in parts: what was found stays.
    @Test
    internal func aListingThatBreaksOffKeepsWhatCame() {
        let breaking = BreakingListingFileSystem()
        let files = FileSystemRegistry()
        files.register(breaking)
        for name in ["a.txt", "b.txt", "c.txt"] { breaking.base.addFile("/s/" + name, "needle") }
        let query = SearchQuery(directory: breaking.base.url("/s"), text: "needle")
        let search = FileSearch(query, fileSystems: files, tuning: FileSearch.Tuning(partialListingAfter: 1))
        var found: [String] = []
        search.run { found.append($0.name) }
        #expect(found == ["a.txt", "b.txt", "c.txt"])
    }

    /// A folder that cannot be listed at all is left out; the others are searched.
    @Test
    internal func aFolderThatCannotBeListedIsLeftOut() {
        memory.addFile("/r/ok/a.txt")
        memory.addFile("/r/closed/b.txt")
        memory.unreadable = ["/r/closed"]
        var found: [String] = []
        FileSearch(SearchQuery(directory: memory.url("/r")), fileSystems: registry).run { found.append($0.name) }
        #expect(found.contains("a.txt") && !found.contains("b.txt"))
    }

    /// Counts calls.
    ///
    /// Unchecked: the count is guarded by `lock`.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        /// Counts one more call and returns the count.
        func next() -> Int {
            lock.withLock {
                count += 1
                return count
            }
        }
    }
}

/// A reader whose every read fails.
private final class FailingReader: FileReader, @unchecked Sendable {
    func read(upToCount _: Int) throws -> Data? { throw CocoaError(.fileReadUnknown) }
    func seek(to _: UInt64) throws { throw CocoaError(.fileReadUnknown) }
    func close() {
        // Nothing to close.
    }
}

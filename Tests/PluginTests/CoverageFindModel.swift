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
    /// A folder on the local disk for the test.
    internal let box: Sandbox
    /// A file system in memory.
    internal let memory = MemoryFileSystem()
    /// The local disk and `memory`.
    internal let registry = FileSystemRegistry()

    /// The folder and the file systems of a test.
    internal init() throws {
        box = try Sandbox()
        registry.register(LocalFileSystem())
        registry.register(memory)
    }

    // MARK: Masks and criteria

    /// A name expression that cannot be read matches no name.
    @Test
    internal func aBrokenExpressionMatchesNoName() {
        #expect(!SearchMask("(", regex: true).matches("x"))
    }

    /// `name.` and `name.*` also match a name without an extension.
    @Test
    internal func aMaskEndingInADotMatchesANameWithoutExtension() {
        #expect(SearchMask("readme.").matches("readme") && !SearchMask("readme.").matches("readme.txt"))
        #expect(SearchMask("read*.*").matches("readme"))
    }

    /// An age the calendar cannot count back reaches the earliest moment there is.
    @Test
    internal func anAgeBeyondTheCalendarReachesBackForever() {
        // The Chinese calendar does not count a million years back.
        let chinese = Calendar(identifier: .chinese)
        #expect(Age(Int.max, .years).cutoff(before: Date(), calendar: chinese) == .distantPast)
    }

    /// `=` in bytes ends one byte later, in kbytes at the next kilobyte.
    @Test
    internal func aSizeInBytesEndsOneByteLater() {
        #expect(SizeRule(.equal, 10).upperBytes == 11 && SizeRule(.equal, 2, .kilobytes).upperBytes == 3_072)
    }

    /// The built-in fields give the path, the date and the permissions as the panels show them.
    @Test
    internal func theBuiltInFieldsShowPathDateAndPermissions() throws {
        let item = FileItem(url: memory.addFile("/f/a.txt", "abc"), name: "a.txt")
        let fields = Dictionary(uniqueKeysWithValues: SearchField.builtIn(fileSystems: registry).map { ($0.id, $0) })
        #expect(try #require(fields["tc.path"]).value(item) == registry.displayPath(memory.url("/f/")))
        #expect(try #require(fields["tc.date"]).value(item) == Format.date(item.modified))
        #expect(try #require(fields["tc.attr"]).value(item) == Format.permissions(item.permissions))
    }

    /// A column with the name of a built-in field gives way to the built-in one.
    @Test
    internal func aColumnOfTheSameNameAsABuiltInFieldGivesWay() {
        let columns = ColumnRegistry()
        columns.register(ContentColumn(id: "tc.name", title: "Other") { _ in "other" })
        var query = SearchQuery(directory: memory.url("/"))
        query.fieldRules = FieldRules(isEnabled: true, rules: [FieldRule("tc.name", .equals, "a.txt")])
        let search = FileSearch(query, fileSystems: registry, columns: columns)
        #expect(search.accepts(FileItem(url: memory.addFile("/a.txt"), name: "a.txt")))
    }

    /// A regex rule matches as an expression; one that takes too long matches nothing.
    @Test
    internal func aRegexRuleIsMatchedAsAnExpression() {
        #expect(FieldRule("tc.name", .regex, "^a.c$").matches("abc"))
        // One that takes too long for the text matches nothing.
        #expect(!FieldRule("tc.name", .regex, "(a*)*b").matches(String(repeating: "a", count: 40)))
    }

    /// With OR, one matching rule is enough.
    @Test
    internal func anyRuleMayMatchWhenAskedSo() {
        let rules = FieldRules(
            isEnabled: true,
            matchAll: false,
            rules: [FieldRule("tc.name", .contains, "zz"), FieldRule("tc.name", .contains, "a")]
        )
        .prepared(trip: nil)
        let item = FileItem(url: memory.addFile("/any/a.txt"), name: "a.txt")
        let fields = Dictionary(uniqueKeysWithValues: SearchField.builtIn(fileSystems: registry).map { ($0.id, $0) })
        #expect(rules.matches(item, fields: fields) { false })
    }

    /// A name the expression takes too long for is no hit, and the search says so.
    @Test
    internal func aNameTheExpressionTakesTooLongForIsNoHit() {
        var query = SearchQuery(directory: memory.url("/"), names: "(a*)*b")
        query.namesAreRegex = true
        let search = FileSearch(query, fileSystems: registry)
        let name = String(repeating: "a", count: 40)
        #expect(!search.accepts(FileItem(url: memory.addFile("/slow/" + name), name: name)))
        #expect(search.regexTimedOut)
    }

    /// Rules tested after a cancel match nothing.
    @Test
    internal func cancelledRulesMatchNothing() {
        let rules = FieldRules(isEnabled: true, rules: [FieldRule("tc.name", .contains, "a")]).prepared(trip: nil)
        let item = FileItem(url: memory.addFile("/a.txt"), name: "a.txt")
        let fields = Dictionary(uniqueKeysWithValues: SearchField.builtIn(fileSystems: registry).map { ($0.id, $0) })
        #expect(rules.matches(item, fields: fields) { false } && !rules.matches(item, fields: fields) { true })
    }

    // MARK: Regular expressions

    /// An empty text is matched as it is, without the progress of a longer match.
    @Test
    internal func anEmptyTextIsMatchedAsIs() throws {
        let empty = try NSRegularExpression(pattern: "^$")
        #expect(FindRegex.firstMatch(empty, in: "", budget: FindRegex.defaultBudget) { false } == .matched)
        let letter = try NSRegularExpression(pattern: "a")
        #expect(FindRegex.firstMatch(letter, in: "", budget: FindRegex.defaultBudget) { false } == .unmatched)
    }

    /// An expression that has run out of time often enough is not tried again.
    @Test
    internal func aTrippedExpressionIsNotTriedAgain() throws {
        let trip = RegexTrip(limit: 1)
        trip.recordTimeout()
        #expect(!FindRegex.matches(try NSRegularExpression(pattern: "a"), in: "a", trip: trip) { false })
    }

    // MARK: Duplicates

    /// A file on a share is told by the share and its path in it.
    @Test
    internal func aShareIsToldByItsSourceAndThePathInIt() throws {
        let mount = DuplicateFinder.Mount(source: "smbfs://host/share", mountPoint: "/Volumes/share")
        #expect(mount.place(of: "/Volumes/share/a/b.txt") == "smbfs://host/share/a/b.txt")
        #expect(mount.place(of: "/elsewhere/c.txt") == "smbfs://host/share/elsewhere/c.txt")
        #expect(DuplicateFinder.Mount(source: "s", mountPoint: "/").place(of: "x") == "s/x")
        // The home folders of the system are mounted by the automounter, not from a local disk.
        let home = try #require(DuplicateFinder.Mount.of(URL(fileURLWithPath: "/System/Volumes/Data/home")))
        #expect(home.mountPoint == "/System/Volumes/Data/home" && home.source.hasPrefix("autofs:"))
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
            DuplicateFinder.Mount(source: "share", mountPoint: url.deletingLastPathComponent().path)
        }
        #expect(kept.map(\.item.url) == [local])
    }

    /// A local file that is gone is no candidate for a duplicate.
    @Test
    internal func aLocalFileThatIsGoneIsLeftOut() throws {
        let here = try box.file("here.txt", "same")
        let items = [here, box.url("gone.txt")].map { FileItem(url: $0, name: $0.lastPathComponent) }
        #expect(
            DuplicateFinder.distinctFiles(items.map { (key: 0, item: $0) }, mountOf: DuplicateFinder.Mount.of)
                .map(\.item.url) == [here]
        )
    }

    /// A digest cancelled while the file is read is none.
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

    /// A search of chosen items cancelled before it runs finds nothing.
    @Test
    internal func aSearchOfChosenItemsThatIsCancelledFindsNothing() {
        let file = memory.addFile("/c/a.txt")
        var query = SearchQuery(directory: memory.url("/c"))
        query.scope = .only([file, memory.url("/c")])
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
        for name in ["a.txt", "b.txt", "c.txt"] {
            breaking.base.addFile("/s/" + name, "needle")
        }
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
}

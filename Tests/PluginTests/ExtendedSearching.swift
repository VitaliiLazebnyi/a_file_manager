import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FindFilesPlugin

/// Searching with the whole form: masks in quotes, expressions, several start directories, chosen
/// items, criteria, text options, field rules, archives and items found elsewhere.
@Suite
internal struct ExtendedSearching {
    /// Stands in for an archive plugin: a file system of its own that reads the location of
    /// `pack.zip` as the root of the archive's contents.
    private final class ArchiveFake: FileSystemProvider {
        let inner = MemoryFileSystem(scheme: "arc")
        var scheme: String { inner.scheme }
        var capabilities: FileSystemCapabilities { [] }

        func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
            try inner.list(directory, showHidden: showHidden)
        }
        func item(at url: URL) -> FileItem? { inner.item(at: url) }
        func parent(of directory: URL) -> URL? { inner.parent(of: directory) }
        func read(_ url: URL) throws -> any FileReader { try inner.read(url) }
        func createDirectory(at _: URL) throws { throw FileSystemError.notSupported("Writing") }
        func write(_: URL) throws -> any FileWriter { throw FileSystemError.notSupported("Writing") }
        func remove(_: URL) throws { throw FileSystemError.notSupported("Writing") }
        func move(_: URL, to _: URL, replacing _: Bool) throws {
            throw FileSystemError.notSupported("Writing")
        }
        func copy(_: URL, to _: URL, progress _: (Int64) -> Bool) throws {
            throw FileSystemError.notSupported("Writing")
        }
        func displayPath(_ url: URL) -> String { inner.displayPath(url) }

        func location(from text: String) -> URL? {
            text.hasSuffix("/store/pack.zip") ? inner.url("/pack") : inner.location(from: text)
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The file systems the searches go through: the local disk and `memory`.
    internal let fileSystems: FileSystemRegistry
    /// A file system in memory with a work folder and another one.
    internal let memory: MemoryFileSystem

    /// The file systems of a test, with the work folder filled.
    internal init() {
        (fileSystems, memory) = makeFileSystems()
        memory.addFile("/work/notes.txt", "meeting about the budget", modified: Date(timeIntervalSince1970: 2_000_000))
        memory.addFile("/work/Budget 2026.xls", "numbers", modified: Date(timeIntervalSince1970: 3_000_000))
        memory.addFile("/work/old/budget.bak", "old budget numbers")
        memory.addFile("/work/old/deep/readme.md", "nothing")
        memory.addFile("/other/budget.txt", "another Budget")
        memory.addFile("/other/photo.jpg", "binary")
    }

    /// The paths a search finds, in the order found.
    internal func find(_ query: SearchQuery) -> [String] {
        find(query, columns: nil)
    }

    /// The paths a search with the columns of `columns` finds, in the order found.
    internal func find(_ query: SearchQuery, columns: ColumnRegistry?) -> [String] {
        var found: [String] = []
        FileSearch(query, fileSystems: fileSystems, columns: columns).run { found.append($0.url.path) }
        return found
    }

    /// A search of `path` in memory for the names `names` and the text `text`.
    internal func query(_ path: String, names: String, text: String) -> SearchQuery {
        SearchQuery(directory: memory.url(path), names: names, text: text)
    }

    /// A name in quotes is one mask, and a name with spaces typed as it is is tried whole too.
    @Test
    internal func masksWithQuotesAndSpaces() {
        #expect(SearchMask("\"Budget 2026.xls\" *.bak").matches("budget 2026.xls"))
        #expect(!SearchMask("\"Budget 2026.xls\" *.bak").matches("Budget.xls"))
        // A name with spaces typed as it is: the whole field is tried as one name.
        #expect(SearchMask("Budget 2026.xls").matches("Budget 2026.xls"))
        #expect(
            SearchMask("*.txt | \"my notes.txt\"").matches("notes.txt")
                && !SearchMask("*.txt | \"my notes.txt\"").matches("my notes.txt")
        )
        // The words still count one by one as well, as the field is read everywhere else.
        #expect(
            find(query("/work", names: "Budget 2026.xls", text: "")) == [
                "/work/Budget 2026.xls", "/work/old/budget.bak"
            ]
        )
        #expect(find(query("/work", names: "\"Budget 2026.xls\"", text: "")) == ["/work/Budget 2026.xls"])
    }

    /// A regular expression for the names matches from the start, and a broken one finds nothing.
    @Test
    internal func regularExpressionForNames() {
        #expect(SearchMask("^budget.*\\.(xls|bak)$", regex: true).matches("Budget 2026.xls"))
        #expect(!SearchMask("^budget.*\\.(xls|bak)$", regex: true).matches("my budget.xls"))
        #expect(SearchMask("", regex: true).matches("anything"))
        var regex = query("/work", names: "^budget", text: "")
        regex.namesAreRegex = true
        #expect(find(regex) == ["/work/Budget 2026.xls", "/work/old/budget.bak"])
        regex.names = "(broken"
        let search = FileSearch(regex, fileSystems: fileSystems)
        #expect(search.problem != nil && find(regex).isEmpty)
    }

    /// Several start directories are searched one after the other, each to the depth.
    @Test
    internal func severalStartDirectoriesAreSearchedInTurn() {
        var several = query("/work", names: "budget", text: "")
        several.moreDirectories = [memory.url("/other")]
        #expect(find(several) == ["/work/Budget 2026.xls", "/work/old/budget.bak", "/other/budget.txt"])
        several.maxDepth = 0
        #expect(find(several) == ["/work/Budget 2026.xls", "/other/budget.txt"])
    }

    /// Chosen files are tested themselves and chosen folders searched inside, as deep as asked.
    @Test
    internal func onlyChosenItemsAreSearched() {
        var chosen = query("/work", names: "*.txt *.bak *.md", text: "")
        chosen.scope = .only([
            memory.url("/work/notes.txt"), memory.url("/work/old"), memory.url("/other/photo.jpg"), memory.url("/gone")
        ])
        // Files are tested themselves, folders searched inside.
        #expect(find(chosen) == ["/work/notes.txt", "/work/old/budget.bak", "/work/old/deep/readme.md"])
        chosen.maxDepth = 1
        #expect(find(chosen) == ["/work/notes.txt", "/work/old/budget.bak"])
        // "Current dir only": only the listed items can be found, never their contents.
        chosen.maxDepth = 0
        chosen.names = ""
        #expect(find(chosen) == ["/work/notes.txt", "/work/old", "/other/photo.jpg"])
        chosen.text = "budget"
        #expect(find(chosen) == ["/work/notes.txt"])
    }

    /// The size, date and attribute criteria narrow the search.
    @Test
    internal func criteriaNarrowTheSearch() {
        var sized = query("/work", names: "", text: "")
        sized.criteria.size = SizeRule(.greater, 10)
        #expect(find(sized) == ["/work/notes.txt", "/work/old/budget.bak"])
        var dated = query("/work", names: "", text: "")
        dated.criteria.dateFrom = Date(timeIntervalSince1970: 2_500_000)
        #expect(find(dated) == ["/work/Budget 2026.xls"])
        var folders = query("/work", names: "", text: "")
        folders.criteria.directory = .set
        #expect(find(folders) == ["/work/old", "/work/old/deep"])
    }

    /// "NOT containing", expressions and hex bytes reach the search; a broken hex string stops it.
    @Test
    internal func textOptionsReachTheSearch() {
        var whole = query("/work", names: "", text: "budget")
        #expect(find(whole) == ["/work/notes.txt", "/work/old/budget.bak"])
        whole.textOptions.notContaining = true
        // The other criteria still count; folders never match a text search.
        #expect(find(whole) == ["/work/Budget 2026.xls", "/work/old/deep/readme.md"])
        var regex = query("/work", names: "", text: "^old\\s+budget")
        regex.textOptions.regex = true
        #expect(find(regex) == ["/work/old/budget.bak"])
        var hex = query("/work", names: "", text: "6E 75 6D \"bers\"")
        hex.textOptions.hex = true
        #expect(find(hex) == ["/work/Budget 2026.xls", "/work/old/budget.bak"])
        hex.text = "6E 7"
        #expect(FileSearch(hex, fileSystems: fileSystems).problem as? TextPattern.Problem == .badHex("6E 7"))
        #expect(find(hex).isEmpty)
    }

    /// Field rules test the built-in fields and the columns of plugins, which come after them.
    @Test
    internal func fieldRulesUseBuiltInFieldsAndPluginColumns() {
        let columns = ColumnRegistry()
        columns.register(
            ContentColumn(id: "comment", title: "Comment") { $0.name.hasPrefix("budget") ? "checked by Ann" : "" }
        )
        var rules = query("/work", names: "", text: "")
        rules.fieldRules = FieldRules(isEnabled: true, rules: [FieldRule("comment", .contains, "ann")])
        #expect(find(rules, columns: columns) == ["/work/old/budget.bak"])
        rules.fieldRules = FieldRules(
            isEnabled: true,
            matchAll: false,
            rules: [FieldRule("tc.ext", .equals, "XLS"), FieldRule("tc.size", .greater, "20")]
        )
        #expect(find(rules, columns: columns) == ["/work/Budget 2026.xls", "/work/notes.txt"])
        rules.fieldRules = FieldRules(
            isEnabled: true,
            rules: [FieldRule("tc.fullname", .regex, "/old/.*\\.md$"), FieldRule("tc.name", .notEquals, "x")]
        )
        #expect(find(rules, columns: columns) == ["/work/old/deep/readme.md"])
        // Without the plugin, its rule matches nothing.
        rules.fieldRules = FieldRules(isEnabled: true, rules: [FieldRule("comment", .contains, "ann")])
        #expect(find(rules).isEmpty)
        let fields = SearchField.all(fileSystems: fileSystems, columns: columns).map(\.id)
        #expect(fields.first == "tc.name" && fields.last == "comment")
    }

    /// Archives are searched like folders where a file system reads their contents.
    @Test
    internal func archivesAreSearchedWhereAFileSystemOffersTheirContents() {
        let archive = ArchiveFake()
        archive.inner.addFile("/pack/inside/budget.txt", "packed budget")
        archive.inner.addFile("/pack/top.txt", "nothing")
        fileSystems.register(archive)
        memory.addFile("/store/pack.zip", "PK")
        memory.addFile("/store/plain.zip", "PK")
        memory.addFile("/store/budget.doc", "x")
        var inArchives = query("/store", names: "budget", text: "")
        #expect(find(inArchives) == ["/store/budget.doc"])
        inArchives.searchArchives = true
        #expect(find(inArchives) == ["/store/budget.doc", "/pack/inside/budget.txt"])
        inArchives.names = ""
        inArchives.text = "packed"
        #expect(find(inArchives) == ["/pack/inside/budget.txt"])
        inArchives.maxDepth = 0
        #expect(find(inArchives).isEmpty)
    }

    /// Many files tested on all cores for text and rules are reported in path order.
    @Test
    internal func manyFilesAreExaminedOnAllCoresAndReportedInOrder() throws {
        let box = try Sandbox()
        for index in 0..<300 {
            try box.file(
                String(format: "d%d/f%03d.txt", index % 3, index),
                index.isMultiple(of: 4) ? "the Schlüssel is here" : "nothing"
            )
        }
        var query = SearchQuery(directory: box.root, text: "schlüssel")
        query.textOptions = TextSearchOptions(wholeWords: true, encodings: [.utf8, .utf16])
        query.fieldRules = FieldRules(isEnabled: true, rules: [FieldRule("tc.name", .regex, "^f\\d+")])
        let expected = (0..<3)
            .flatMap { folder in
                stride(from: 0, to: 300, by: 4).filter { $0 % 3 == folder }
                    .map { index in
                        String(format: "d%d/f%03d.txt", folder, index)
                    }
            }
        var found: [String] = []
        FileSearch(query, fileSystems: fileSystems)
            .run { item in
                found.append(String(item.url.path.dropFirst(box.root.path.count + 1)))
            }
        #expect(found == expected)
    }

    /// An item found by other means is checked against every criterion, the text if asked.
    @Test
    internal func acceptsChecksAnItemFoundElsewhere() throws {
        var query = query("/work", names: "*.txt", text: "budget")
        query.criteria.size = SizeRule(.greater, 5)
        let search = FileSearch(query, fileSystems: fileSystems)
        let notes = try #require(memory.item(at: memory.url("/work/notes.txt")))
        let photo = try #require(memory.item(at: memory.url("/other/photo.jpg")))
        let other = try #require(memory.item(at: memory.url("/other/budget.txt")))
        #expect(search.accepts(notes) && !search.accepts(photo) && search.accepts(other))
        memory.addFile("/work/empty.txt", "no such word")
        let empty = try #require(memory.item(at: memory.url("/work/empty.txt")))
        #expect(!search.accepts(empty) && search.accepts(empty, checkingText: false))
    }
}

import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FindFilesPlugin

@Suite struct TextPatterns {
    func pattern(_ text: String, caseSensitive: Bool = false, _ options: TextSearchOptions = TextSearchOptions()) throws
        -> TextPattern
    {
        try TextPattern(text, caseSensitive: caseSensitive, options: options)
    }

    @Test func plainTextIgnoresCaseUnlessAsked() throws {
        let data = Data("Quarterly REPORT for Ärger GmbH".utf8)
        #expect(try pattern("report").isFound(in: data))
        #expect(try !pattern("report", caseSensitive: true).isFound(in: data))
        #expect(try pattern("REPORT", caseSensitive: true).isFound(in: data))
        #expect(try pattern("ärger").isFound(in: data))
        #expect(try pattern("ÄRGER gmbh").isFound(in: data))
        #expect(try !pattern("ärger", caseSensitive: true).isFound(in: data))
    }

    @Test func escapesStandForTabAndLineBreak() throws {
        #expect(TextPattern.unescape("a\\tb\\nc\\\\d\\x") == "a\tb\nc\\d\\x")
        #expect(try pattern("one\\ttwo").isFound(in: Data("one\ttwo".utf8)))
        #expect(try pattern("end\\nstart").isFound(in: Data("end\nstart".utf8)))
    }

    @Test func wholeWords() throws {
        let words = TextSearchOptions(wholeWords: true)
        #expect(try pattern("port", words).isFound(in: Data("the port is open".utf8)))
        #expect(try pattern("port", words).isFound(in: Data("port".utf8)))
        #expect(try pattern("port", words).isFound(in: Data("(port)".utf8)))
        #expect(try !pattern("port", words).isFound(in: Data("a report here".utf8)))
        #expect(try !pattern("port", words).isFound(in: Data("portable".utf8)))
        #expect(try !pattern("port", words).isFound(in: Data("port_2".utf8)))
        // A later occurrence counts when the first one is part of a longer word.
        #expect(try pattern("port", words).isFound(in: Data("report, port".utf8)))
    }

    @Test func hitsAcrossBlockBordersAreFoundWithTheirSurroundings() throws {
        let text = String(repeating: "x", count: 61) + " needle " + String(repeating: "y", count: 40) + " needles"
        let words = TextSearchOptions(wholeWords: true)
        for blockSize in 1...40 {
            #expect(try pattern("NEEDLE").isFound(in: Data(text.utf8), blockSize: blockSize))
            #expect(try pattern("needle", words).isFound(in: Data(text.utf8), blockSize: blockSize))
            #expect(try !pattern("needl", words).isFound(in: Data(text.utf8), blockSize: blockSize))
            #expect(try !pattern("eedle", words).isFound(in: Data(text.utf8), blockSize: blockSize))
            #expect(try pattern("needles", words).isFound(in: Data(text.utf8), blockSize: blockSize))
        }
    }

    @Test func encodings() throws {
        let text = "Grüße aus Köln"
        let latin = try #require(text.data(using: .windowsCP1252))
        let dos = try #require(text.data(using: TextEncoding.dos.stringEncoding))
        let little = try #require(text.data(using: .utf16LittleEndian))
        let big = try #require(text.data(using: .utf16BigEndian))
        func found(_ encoding: TextEncoding, in data: Data) throws -> Bool {
            try pattern("grüße", TextSearchOptions(encodings: [encoding])).isFound(in: data)
        }
        #expect(try found(.utf8, in: Data(text.utf8)) && !found(.utf8, in: latin) && !found(.utf8, in: little))
        #expect(try found(.western, in: latin) && !found(.western, in: Data(text.utf8)))
        #expect(try found(.dos, in: dos) && !found(.dos, in: latin))
        #expect(try found(.utf16, in: little) && found(.utf16, in: big) && !found(.utf16, in: latin))
        // Any of the ticked encodings will do.
        let all = TextSearchOptions(encodings: TextEncoding.allCases)
        for data in [Data(text.utf8), latin, dos, little, big] { #expect(try pattern("köln", all).isFound(in: data)) }
        // Whole words look at whole UTF-16 units.
        let words = TextSearchOptions(wholeWords: true, encodings: [.utf16])
        #expect(try pattern("aus", words).isFound(in: little) && pattern("aus", words).isFound(in: big))
        #expect(try !pattern("au", words).isFound(in: little))
    }

    @Test func textThatAnEncodingCannotWriteDropsThatEncoding() throws {
        let both = try pattern("日本", TextSearchOptions(encodings: [.western, .utf8]))
        #expect(both.droppedEncodings == [.western])
        #expect(both.isFound(in: Data("in 日本 gewesen".utf8)))
        #expect(throws: TextPattern.Problem.notRepresentable("日本")) {
            try pattern("日本", TextSearchOptions(encodings: [.western, .dos]))
        }
        #expect(throws: TextPattern.Problem.emptyText) { try pattern("") }
    }

    @Test func hexBytes() throws {
        let hex = TextSearchOptions(hex: true)
        let data = Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0xFF, 0x12])
        #expect(try pattern("00 FF 12", hex).isFound(in: data))
        #expect(try pattern("00ff12", hex).isFound(in: data))
        #expect(try pattern("\"PK\"0304", caseSensitive: true, hex).isFound(in: data))
        #expect(try !pattern("00 FF 13", hex).isFound(in: data))
        // The code of a lowercase letter also finds the uppercase letter, not the other way round.
        #expect(try pattern("6B", hex).isFound(in: Data("K".utf8)) && pattern("6B", hex).isFound(in: Data("k".utf8)))
        #expect(try !pattern("6B", caseSensitive: true, hex).isFound(in: Data("K".utf8)))
        #expect(try !pattern("4B", hex).isFound(in: Data("k".utf8)))
        for broken in ["0", "0G", "\"open", "12 3"] {
            #expect(throws: TextPattern.Problem.badHex(broken)) { try pattern(broken, hex) }
        }
    }

    @Test func regularExpressionsMatchLineByLine() throws {
        let regex = TextSearchOptions(regex: true)
        let data = Data("first line\nError 42: disk full\r\nlast line".utf8)
        #expect(try pattern("^error \\d+", regex).isFound(in: data))
        #expect(try !pattern("^error \\d+", caseSensitive: true, regex).isFound(in: data))
        #expect(try pattern("full$", regex).isFound(in: data))
        #expect(try !pattern("line.+Error", regex).isFound(in: data))
        #expect(try pattern("^last", regex).isFound(in: data, blockSize: 7))
        #expect(try pattern("disk", TextSearchOptions(wholeWords: true, regex: true)).isFound(in: data))
        #expect(try !pattern("dis", TextSearchOptions(wholeWords: true, regex: true)).isFound(in: data))
        #expect(throws: TextPattern.Problem.self) { try pattern("(open", regex) }
    }

    @Test func regularExpressionsInOtherEncodings() throws {
        let text = "erste Zeile\nGröße: 12 cm\nEnde"
        let utf16 = TextSearchOptions(regex: true, encodings: [.utf16])
        var withMark = Data([0xFE, 0xFF])
        withMark.append(try #require(text.data(using: .utf16BigEndian)))
        #expect(
            try pattern("^größe: \\d+", utf16)
                .isFound(
                    in: try #require(text.data(using: .utf16LittleEndian)),
                    blockSize: 9
                )
        )
        #expect(try pattern("^größe: \\d+", utf16).isFound(in: withMark, blockSize: 9))
        let western = TextSearchOptions(regex: true, encodings: [.western])
        #expect(try pattern("^größe", western).isFound(in: try #require(text.data(using: .windowsCP1252))))
        #expect(try !pattern("^größe", western).isFound(in: Data(text.utf8)))
    }
}

@Suite struct SearchCriteriaRules {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func date(_ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2_026, month: 10, day: day, hour: hour))!
    }

    func file(
        _ name: String = "a.txt",
        size: Int64 = 0,
        modified: Date = Date(timeIntervalSince1970: 0),
        permissions: UInt16 = 0o644,
        directory: Bool = false,
        hidden: Bool = false,
        symlink: Bool = false,
        package: Bool = false
    ) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: "/x/" + name),
            name: name,
            kind: .init(isDirectory: directory, isSymlink: symlink, isPackage: package, isHidden: hidden),
            stat: .init(size: size, modified: modified, permissions: permissions)
        )
    }

    @Test func ageCutsOffAtMidnightForDaysAndLonger() {
        let now = date(12, 15)
        #expect(Age(3, .hours).cutoff(before: now, calendar: calendar) == date(12, 12))
        #expect(Age(90, .minutes).cutoff(before: now, calendar: calendar) == now.addingTimeInterval(-5_400))
        #expect(Age(2, .days).cutoff(before: now, calendar: calendar) == date(10, 0))
        #expect(Age(1, .weeks).cutoff(before: now, calendar: calendar) == date(5, 0))
        #expect(
            Age(1, .months).cutoff(before: now, calendar: calendar)
                == calendar.date(from: DateComponents(year: 2_026, month: 9, day: 12))
        )
        #expect(
            Age(1, .years).cutoff(before: now, calendar: calendar)
                == calendar.date(from: DateComponents(year: 2_025, month: 10, day: 12))
        )
    }

    @Test func dateCriteria() {
        let now = date(12, 15)
        var criteria = FileCriteria(notOlderThan: Age(2, .days))
        #expect(criteria.matches(file(modified: date(10, 1)), now: now, calendar: calendar))
        #expect(!criteria.matches(file(modified: date(9, 23)), now: now, calendar: calendar))
        // Older than 2 days but not older than 7: a window.
        criteria = FileCriteria(notOlderThan: Age(7, .days), olderThan: Age(2, .days))
        #expect(criteria.matches(file(modified: date(7)), now: now, calendar: calendar))
        #expect(!criteria.matches(file(modified: date(11)), now: now, calendar: calendar))
        #expect(!criteria.matches(file(modified: date(2)), now: now, calendar: calendar))
        criteria = FileCriteria(dateFrom: date(3, 0), dateTo: date(5, 23))
        #expect(
            criteria.matches(file(modified: date(4)), now: now)
                && criteria.matches(file(modified: date(5, 22)), now: now)
        )
        #expect(
            !criteria.matches(file(modified: date(2)), now: now)
                && !criteria.matches(file(modified: date(6)), now: now)
        )
        #expect(FileCriteria(dateFrom: date(3)).matches(file(modified: date(30)), now: now))
        #expect(FileCriteria().isEmpty && !criteria.isEmpty)
    }

    @Test func sizeRules() {
        #expect(SizeRule(.equal, 19).matches(19) && !SizeRule(.equal, 19).matches(20))
        #expect(SizeRule(.greater, 1, .kilobytes).matches(1_025) && !SizeRule(.greater, 1, .kilobytes).matches(1_024))
        #expect(
            SizeRule(.less, 0.5, .megabytes).matches(524_287) && !SizeRule(.less, 0.5, .megabytes).matches(524_288)
        )
        #expect(SizeRule(.equal, 2, .kilobytes).matches(2_048) && SizeRule(.equal, 2, .kilobytes).matches(3_071))
        #expect(!SizeRule(.equal, 2, .kilobytes).matches(3_072) && !SizeRule(.equal, 2, .kilobytes).matches(2_047))
        #expect(
            SizeRule(.greater, 0.1, .gigabytes).matches(107_374_183)
                && !SizeRule(.greater, 0.1, .gigabytes).matches(107_374_182)
        )
        let criteria = FileCriteria(size: SizeRule(.greater, 10))
        #expect(criteria.matches(file(size: 11), now: Date()) && !criteria.matches(file(size: 10), now: Date()))
        // Folders have no size to compare.
        #expect(!criteria.matches(file("dir", size: 100, directory: true), now: Date()))
    }

    @Test func attributesAreTriState() {
        var criteria = FileCriteria()
        #expect(!criteria.hasAttributes)
        criteria.hidden = .yes
        criteria.directory = .no
        #expect(criteria.hasAttributes)
        #expect(criteria.matches(file(hidden: true), now: Date()))
        #expect(
            !criteria.matches(file(), now: Date())
                && !criteria.matches(file(directory: true, hidden: true), now: Date())
        )
        criteria = FileCriteria()
        criteria.readOnly = .yes
        criteria.executable = .no
        #expect(criteria.matches(file(permissions: 0o444), now: Date()))
        #expect(
            !criteria.matches(file(permissions: 0o644), now: Date())
                && !criteria.matches(file(permissions: 0o555), now: Date())
        )
        criteria = FileCriteria()
        (criteria.symbolicLink, criteria.package) = (.yes, .no)
        #expect(
            criteria.matches(file(symlink: true), now: Date())
                && !criteria.matches(file(symlink: true, package: true), now: Date())
        )
    }

    @Test func fieldRuleOperators() {
        func rule(_ comparison: FieldRule.Operator, _ value: String) -> FieldRule { FieldRule("f", comparison, value) }
        #expect(rule(.contains, "CAM").matches("TestCam 3") && !rule(.containsCase, "CAM").matches("TestCam 3"))
        #expect(rule(.notContains, "nikon").matches("TestCam") && rule(.notContainsCase, "cam").matches("TestCam"))
        #expect(rule(.equals, "testcam").matches("TestCam") && !rule(.equalsCase, "testcam").matches("TestCam"))
        #expect(
            rule(.notEquals, "x").matches("y") && !rule(.notEquals, "X").matches("x")
                && rule(.notEqualsCase, "X").matches("x")
        )
        #expect(rule(.regex, "^test\\w+$").matches("TestCam") && rule(.notRegex, "^cam").matches("TestCam"))
        #expect(
            rule(.greater, "1000").matches("1,024") && !rule(.greater, "1024").matches("1,024")
                && rule(.greaterOrEqual, "1024").matches("1,024")
        )
        #expect(rule(.less, "9").matches("10") == false && rule(.lessOrEqual, "10").matches("10"))
        // Text is ordered as text; an empty field is neither more nor less.
        #expect(rule(.greater, "apple").matches("Banana") && !rule(.less, "apple").matches(""))
        #expect(FieldRule.Operator.allCases.map(\.title).count == Set(FieldRule.Operator.allCases.map(\.title)).count)
    }

    @Test func fieldRulesCombineWithAndOrOr() {
        let fields = [
            "len": SearchField(id: "len", title: "Length") { String($0.name.count) },
            "name": SearchField(id: "name", title: "Name") { $0.name }
        ]
        let rules = [FieldRule("len", .greater, "5"), FieldRule("name", .contains, "b")]
        #expect(FieldRules(isEnabled: true, matchAll: true, rules: rules).matches(file("abcdef"), fields: fields))
        #expect(!FieldRules(isEnabled: true, matchAll: true, rules: rules).matches(file("abc"), fields: fields))
        #expect(FieldRules(isEnabled: true, matchAll: false, rules: rules).matches(file("abc"), fields: fields))
        #expect(!FieldRules(isEnabled: true, matchAll: false, rules: rules).matches(file("xyz"), fields: fields))
        // Switched off, the list is kept but does not count; a field that is gone never matches.
        #expect(FieldRules(isEnabled: false, rules: rules).matches(file("xyz"), fields: fields))
        #expect(
            !FieldRules(isEnabled: true, rules: [FieldRule("gone", .contains, "")])
                .matches(
                    file("xyz"),
                    fields: fields
                )
        )
    }
}

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
}

@Suite struct ExtendedSearching {
    let fileSystems: FileSystemRegistry
    let memory: MemoryFileSystem

    init() {
        (fileSystems, memory) = makeFileSystems()
        memory.addFile("/work/notes.txt", "meeting about the budget", modified: Date(timeIntervalSince1970: 2_000_000))
        memory.addFile("/work/Budget 2026.xls", "numbers", modified: Date(timeIntervalSince1970: 3_000_000))
        memory.addFile("/work/old/budget.bak", "old budget numbers")
        memory.addFile("/work/old/deep/readme.md", "nothing")
        memory.addFile("/other/budget.txt", "another Budget")
        memory.addFile("/other/photo.jpg", "binary")
    }

    func find(_ query: SearchQuery, columns: ColumnRegistry? = nil) -> [String] {
        var found: [String] = []
        FileSearch(query, fileSystems: fileSystems, columns: columns).run { found.append($0.url.path) }
        return found
    }

    func query(_ path: String = "/work", names: String = "", text: String = "") -> SearchQuery {
        SearchQuery(directory: memory.url(path), names: names, text: text)
    }

    @Test func masksWithQuotesAndSpaces() {
        #expect(SearchMask("\"Budget 2026.xls\" *.bak").matches("budget 2026.xls"))
        #expect(!SearchMask("\"Budget 2026.xls\" *.bak").matches("Budget.xls"))
        // A name with spaces typed as it is: the whole field is tried as one name.
        #expect(SearchMask("Budget 2026.xls").matches("Budget 2026.xls"))
        #expect(
            SearchMask("*.txt | \"my notes.txt\"").matches("notes.txt")
                && !SearchMask("*.txt | \"my notes.txt\"").matches("my notes.txt")
        )
        // The words still count one by one as well, as the field is read everywhere else.
        #expect(find(query(names: "Budget 2026.xls")) == ["/work/Budget 2026.xls", "/work/old/budget.bak"])
        #expect(find(query(names: "\"Budget 2026.xls\"")) == ["/work/Budget 2026.xls"])
    }

    @Test func regularExpressionForNames() {
        #expect(SearchMask("^budget.*\\.(xls|bak)$", regex: true).matches("Budget 2026.xls"))
        #expect(!SearchMask("^budget.*\\.(xls|bak)$", regex: true).matches("my budget.xls"))
        #expect(SearchMask("", regex: true).matches("anything"))
        var regex = query(names: "^budget")
        regex.namesAreRegex = true
        #expect(find(regex) == ["/work/Budget 2026.xls", "/work/old/budget.bak"])
        regex.names = "(broken"
        let search = FileSearch(regex, fileSystems: fileSystems)
        #expect(search.problem != nil && find(regex).isEmpty)
    }

    @Test func severalStartDirectoriesAreSearchedInTurn() {
        var several = query(names: "budget")
        several.moreDirectories = [memory.url("/other")]
        #expect(find(several) == ["/work/Budget 2026.xls", "/work/old/budget.bak", "/other/budget.txt"])
        several.maxDepth = 0
        #expect(find(several) == ["/work/Budget 2026.xls", "/other/budget.txt"])
    }

    @Test func onlyChosenItemsAreSearched() {
        var chosen = query(names: "*.txt *.bak *.md")
        chosen.onlyItems = [
            memory.url("/work/notes.txt"), memory.url("/work/old"), memory.url("/other/photo.jpg"), memory.url("/gone")
        ]
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

    @Test func criteriaNarrowTheSearch() {
        var sized = query()
        sized.criteria.size = SizeRule(.greater, 10)
        #expect(find(sized) == ["/work/notes.txt", "/work/old/budget.bak"])
        var dated = query()
        dated.criteria.dateFrom = Date(timeIntervalSince1970: 2_500_000)
        #expect(find(dated) == ["/work/Budget 2026.xls"])
        var folders = query()
        folders.criteria.directory = .yes
        #expect(find(folders) == ["/work/old", "/work/old/deep"])
    }

    @Test func textOptionsReachTheSearch() {
        var whole = query(text: "budget")
        #expect(find(whole) == ["/work/notes.txt", "/work/old/budget.bak"])
        whole.textOptions.notContaining = true
        // The other criteria still count; folders never match a text search.
        #expect(find(whole) == ["/work/Budget 2026.xls", "/work/old/deep/readme.md"])
        var regex = query(text: "^old\\s+budget")
        regex.textOptions.regex = true
        #expect(find(regex) == ["/work/old/budget.bak"])
        var hex = query(text: "6E 75 6D \"bers\"")
        hex.textOptions.hex = true
        #expect(find(hex) == ["/work/Budget 2026.xls", "/work/old/budget.bak"])
        hex.text = "6E 7"
        #expect(FileSearch(hex, fileSystems: fileSystems).problem as? TextPattern.Problem == .badHex("6E 7"))
        #expect(find(hex).isEmpty)
    }

    @Test func fieldRulesUseBuiltInFieldsAndPluginColumns() {
        let columns = ColumnRegistry()
        columns.register(
            ContentColumn(id: "comment", title: "Comment") { $0.name.hasPrefix("budget") ? "checked by Ann" : "" }
        )
        var rules = query()
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

    @Test func archivesAreSearchedWhereAFileSystemOffersTheirContents() {
        let archive = ArchiveFake()
        archive.inner.addFile("/pack/inside/budget.txt", "packed budget")
        archive.inner.addFile("/pack/top.txt", "nothing")
        fileSystems.register(archive)
        memory.addFile("/store/pack.zip", "PK")
        memory.addFile("/store/plain.zip", "PK")
        memory.addFile("/store/budget.doc", "x")
        var inArchives = query("/store", names: "budget")
        #expect(find(inArchives) == ["/store/budget.doc"])
        inArchives.searchArchives = true
        #expect(find(inArchives) == ["/store/budget.doc", "/pack/inside/budget.txt"])
        inArchives.names = ""
        inArchives.text = "packed"
        #expect(find(inArchives) == ["/pack/inside/budget.txt"])
        inArchives.maxDepth = 0
        #expect(find(inArchives).isEmpty)
    }

    @Test func manyFilesAreExaminedOnAllCoresAndReportedInOrder() throws {
        let box = try Sandbox()
        for index in 0..<300 {
            try box.file(
                String(format: "d%d/f%03d.txt", index % 3, index),
                index % 4 == 0 ? "the Schlüssel is here" : "nothing"
            )
        }
        var query = SearchQuery(directory: box.root, text: "schlüssel")
        query.textOptions = TextSearchOptions(wholeWords: true, encodings: [.utf8, .utf16])
        query.fieldRules = FieldRules(isEnabled: true, rules: [FieldRule("tc.name", .regex, "^f\\d+")])
        let expected = (0..<3)
            .flatMap { folder in
                stride(from: 0, to: 300, by: 4).filter { $0 % 3 == folder }
                    .map {
                        String(format: "d%d/f%03d.txt", folder, $0)
                    }
            }
        var found: [String] = []
        FileSearch(query, fileSystems: fileSystems)
            .run {
                found.append(String($0.url.path.dropFirst(box.root.path.count + 1)))
            }
        #expect(found == expected)
    }

    @Test func acceptsChecksAnItemFoundElsewhere() throws {
        var query = query(names: "*.txt", text: "budget")
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

@Suite struct Duplicates {
    let fileSystems: FileSystemRegistry
    let memory: MemoryFileSystem

    init() {
        (fileSystems, memory) = makeFileSystems()
        memory.addFile("/d/A/copy.txt", "same content")
        memory.addFile("/d/B/copy.txt", "same content")
        memory.addFile("/d/C/COPY.TXT", "other content")
        memory.addFile("/d/A/alpha.bin", "12345")
        memory.addFile("/d/B/beta.bin", "12345")
        memory.addFile("/d/B/gamma.bin", "54321")
        memory.addFile("/d/C/single.txt", "only one of its kind")
    }

    func groups(_ options: DuplicateOptions) -> [[String]] {
        var query = SearchQuery(directory: memory.url("/d"))
        query.duplicates = options
        return FileSearch(query, fileSystems: fileSystems).runForDuplicates().map { $0.map(\.url.path) }
    }

    @Test func sameNameAndSize() {
        #expect(groups(DuplicateOptions(isEnabled: true)) == [["/d/A/copy.txt", "/d/B/copy.txt"]])
        #expect(
            groups(DuplicateOptions(isEnabled: true, sameName: true, sameSize: false))
                == [["/d/A/copy.txt", "/d/B/copy.txt", "/d/C/COPY.TXT"]]
        )
    }

    @Test func sameSizeGroupsAreOrderedBySize() {
        #expect(
            groups(DuplicateOptions(isEnabled: true, sameName: false, sameSize: true))
                == [["/d/A/alpha.bin", "/d/B/beta.bin", "/d/B/gamma.bin"], ["/d/A/copy.txt", "/d/B/copy.txt"]]
        )
    }

    @Test func sameContentsIsDecidedByHashing() {
        #expect(
            groups(DuplicateOptions(isEnabled: true, sameName: false, sameSize: false, sameContents: true))
                == [["/d/A/alpha.bin", "/d/B/beta.bin"], ["/d/A/copy.txt", "/d/B/copy.txt"]]
        )
        #expect(
            groups(DuplicateOptions(isEnabled: true, sameName: true, sameSize: false, sameContents: true))
                == [["/d/A/copy.txt", "/d/B/copy.txt"]]
        )
        #expect(
            DuplicateFinder.digest(of: memory.url("/d/A/copy.txt"), fileSystems: fileSystems)
                == DuplicateFinder.digest(of: memory.url("/d/B/copy.txt"), fileSystems: fileSystems)
        )
        #expect(DuplicateFinder.digest(of: memory.url("/d/gone"), fileSystems: fileSystems) == nil)
    }

    @Test func noSubCriterionSwitchesTheOptionOff() {
        let none = DuplicateOptions(isEnabled: true, sameName: false, sameSize: false, sameContents: false)
        #expect(!none.isActive && groups(none).isEmpty)
        #expect(!DuplicateOptions().isActive)
    }

    @Test func manyFilesAreHashedOnAllCores() throws {
        let box = try Sandbox()
        for index in 0..<240 {
            try box.file(
                String(format: "set%d/file%03d.dat", index % 2, index),
                "payload \(index / 2 % 40)".padding(toLength: 16, withPad: " ", startingAt: 0)
            )
        }
        var query = SearchQuery(directory: box.root)
        query.duplicates = DuplicateOptions(isEnabled: true, sameName: false, sameSize: true, sameContents: true)
        // Used by the callbacks, which run one at a time while the calls below wait for them.
        nonisolated(unsafe) var steps: [Int] = []
        let found = FileSearch(query, fileSystems: fileSystems)
            .runForDuplicates(onHashing: { done, total in
                steps.append(done)
                #expect(total == 240)
            })
        #expect(found.count == 40 && found.allSatisfy { $0.count == 6 })
        #expect(steps == Array(1...240))
        #expect(found.allSatisfy { group in group.map(\.url.path) == group.map(\.url.path).sorted() })
    }

    @Test func aCancelledRunShowsNothing() {
        var query = SearchQuery(directory: memory.url("/d"))
        query.duplicates = DuplicateOptions(isEnabled: true, sameName: false, sameSize: false, sameContents: true)
        let search = FileSearch(query, fileSystems: fileSystems)
        search.cancel()
        #expect(search.runForDuplicates().isEmpty)
        let items = ["/d/A/copy.txt", "/d/B/copy.txt"].compactMap { memory.item(at: memory.url($0)) }
        let cancelled = CancellationFlag()
        cancelled.cancel()
        #expect(
            DuplicateFinder.groups(
                of: items,
                options: query.duplicates,
                fileSystems: fileSystems,
                cancellation: cancelled
            )
            .isEmpty
        )
        #expect(DuplicateFinder.groups(of: items, options: query.duplicates, fileSystems: fileSystems).count == 1)
    }
}

@Suite struct SavedSearches {
    func settings(_ searchFor: String, in searchIn: String = "") -> SearchSettings {
        var settings = SearchSettings()
        (settings.searchFor, settings.searchIn) = (searchFor, searchIn)
        return settings
    }

    @Test func savingLoadingAndDeleting() {
        let memory = MemorySettings()
        let store = SearchStore(settings: memory)
        #expect(store.searches.isEmpty)
        var pictures = settings("*.jpg *.png")
        pictures.criteria.size = SizeRule(.greater, 1, .megabytes)
        pictures.duplicates = DuplicateOptions(isEnabled: true, sameContents: true)
        store.save(SavedSearch(name: "Pictures", settings: pictures))
        store.save(SavedSearch(name: "backups", settings: settings("*.bak")))
        #expect(store.searches.map(\.name) == ["backups", "Pictures"])
        // Kept in the settings, in the plugin's own corner; a second store reads the same.
        #expect(memory.data(forKey: "findFiles.searches") != nil)
        #expect(SearchStore(settings: memory)["pictures"]?.settings == pictures)
        store.save(SavedSearch(name: "PICTURES", settings: settings("*.gif")))
        #expect(
            store.searches.map(\.name) == ["backups", "PICTURES"] && store["Pictures"]?.settings.searchFor == "*.gif"
        )
        store.delete(named: "Backups")
        #expect(store.searches.map(\.name) == ["PICTURES"])
    }

    @Test func aLeadingAngleKeepsTheFieldOfTheWindow() {
        let current = settings("*.swift", in: "/Users/x/src")
        var saved = settings(">", in: ">")
        saved.depth = 2
        let loaded = saved.loaded(over: current)
        #expect(loaded.searchFor == "*.swift" && loaded.searchIn == "/Users/x/src" && loaded.depth == 2)
        #expect(settings("*.md", in: "/tmp").loaded(over: current).searchFor == "*.md")
    }

    @Test func summaryNamesWhatIsNotDefault() {
        #expect(SearchSettings().summary.isEmpty)
        var all = settings("*.txt")
        (all.namesAreRegex, all.findText, all.text, all.searchArchives, all.depth, all.useSpotlight) = (
            true, true, "x", true, 3, true
        )
        all.criteria.olderThan = Age(1, .days)
        all.criteria.size = SizeRule(.less, 5)
        all.criteria.hidden = .yes
        all.duplicates = DuplicateOptions(isEnabled: true)
        all.fieldRules = FieldRules(isEnabled: true, rules: [FieldRule("tc.name", .contains, "a")])
        #expect(all.summary == "*.txt, regex, text \"x\", date, zip, size, attr, 2x, D<=3, plugins, Spotlight")
    }

    @Test func fieldHistoriesKeepTheNewestFirst() {
        let store = SearchStore(settings: MemorySettings())
        for text in ["a", "b", "c", "a", ""] { store.remember(text, in: .searchFor, limit: 2) }
        #expect(store.history(.searchFor) == ["a", "c"] && store.history(.text).isEmpty)
        store.forget("a", in: .searchFor)
        #expect(store.history(.searchFor) == ["c"])
    }

    @Test func settingsBecomeAQuery() {
        let (fileSystems, memory) = makeFileSystems()
        var form = settings("*.txt", in: " mem:/work ; /tmp/x;sub ;")
        (form.findText, form.text, form.caseSensitive, form.depth) = (false, "ignored", true, 1)
        form.onlySelected = true
        let base = memory.url("/base")
        var query = form.query(relativeTo: base, fileSystems: fileSystems, includeHidden: true)
        #expect(query.directories.map(\.absoluteString) == ["mem:///work", "mem:///tmp/x", "mem:///base/sub"])
        #expect(
            query.names == "*.txt" && query.text.isEmpty && query.caseSensitive && query.includeHidden
                && query.maxDepth == 1
        )
        // Nothing marked in the panel: the option has nothing to work on.
        #expect(query.onlyItems == nil)
        form.findText = true
        form.searchIn = ""
        query = form.query(
            relativeTo: base,
            fileSystems: fileSystems,
            includeHidden: false,
            selected: [memory.url("/base/a")]
        )
        #expect(query.directories == [base] && query.text == "ignored" && query.onlyItems == [memory.url("/base/a")])
    }
}

@Suite struct SpotlightQueries {
    func query(names: String = "", text: String = "") -> SearchQuery {
        SearchQuery(directory: URL(fileURLWithPath: "/Users/x"), names: names, text: text)
    }

    @Test func questionsInSpotlightsLanguage() {
        #expect(SpotlightQuery.string(for: query()) == "kMDItemFSName == \"*\"")
        #expect(
            SpotlightQuery.string(for: query(names: "*.txt report | *.bak"))
                == "(kMDItemFSName == \"*.txt\"c || kMDItemFSName == \"*report*\"c) && kMDItemFSName != \"*.bak\"c"
        )
        #expect(SpotlightQuery.string(for: query(names: "file_??.txt")) == "(kMDItemFSName == \"file_**.txt\"c)")
        #expect(SpotlightQuery.string(for: query(names: "*.* | a\\b")) == "kMDItemFSName != \"*a\\\\b*\"c")
        #expect(SpotlightQuery.string(for: query(text: "50* off")) == "kMDItemTextContent == \"*50\\* off*\"cd")
        var sensitive = query(names: "*.md", text: "Smith")
        sensitive.caseSensitive = true
        sensitive.textOptions.wholeWords = true
        #expect(
            SpotlightQuery.string(for: sensitive) == "(kMDItemFSName == \"*.md\"c) && kMDItemTextContent == \"Smith\"w"
        )
    }

    @Test func sizesAndDates() {
        var sized = query()
        sized.criteria.size = SizeRule(.equal, 2, .kilobytes)
        sized.criteria.dateFrom = Date(timeIntervalSince1970: 0)
        sized.criteria.olderThan = Age(1, .hours)
        let now = Date(timeIntervalSince1970: 7_200)
        #expect(
            SpotlightQuery.string(for: sized, now: now)
                == "(kMDItemFSSize >= 2048 && kMDItemFSSize < 3072) && kMDItemFSContentChangeDate >= $time.iso(1970-01-01T00:00:00Z)"
                + " && kMDItemFSContentChangeDate < $time.iso(1970-01-01T01:00:00Z)"
        )
        sized.criteria = FileCriteria(size: SizeRule(.greater, 1.5, .megabytes))
        #expect(SpotlightQuery.string(for: sized) == "kMDItemFSSize > 1572864")
    }

    @Test func spotlightUnderstandsEveryQuestion() {
        var full = query(names: "*.txt \"my file.doc\" | *.bak a\"b", text: "a \"quoted\" \\ text*")
        full.criteria = FileCriteria(
            dateFrom: Date(),
            dateTo: Date(),
            notOlderThan: Age(3, .days),
            olderThan: Age(1, .minutes),
            size: SizeRule(.less, 0.5, .gigabytes)
        )
        for query in [query(), query(names: "report"), full] {
            #expect(NSPredicate(fromMetadataQueryString: SpotlightQuery.string(for: query)) != nil)
        }
    }

    @Test func whatTheIndexCannotAnswerIsLeftToTheSearch() {
        var regex = query(names: "^a", text: "x+")
        regex.namesAreRegex = true
        regex.textOptions.regex = true
        #expect(SpotlightQuery.string(for: regex) == "kMDItemFSName == \"*\"" && !SpotlightQuery.handlesText(of: regex))
        var not = query(text: "x")
        #expect(SpotlightQuery.handlesText(of: not))
        not.textOptions.notContaining = true
        #expect(!SpotlightQuery.handlesText(of: not) && !SpotlightQuery.handlesText(of: query()))
        #expect(SpotlightQuery.isAvailable(for: query()))
        var remote = query()
        remote.moreDirectories = [URL(string: "mem:///x")!]
        #expect(!SpotlightQuery.isAvailable(for: remote))
        var chosen = query()
        chosen.onlyItems = []
        #expect(!SpotlightQuery.isAvailable(for: chosen))
    }

    @Test func answersAreCheckedAgainstTheWholeSearch() throws {
        let box = try Sandbox()
        try box.file("a/report.txt", "about apples")
        try box.file("a/deep/report.txt", "about apples")
        try box.file("a/notes.md", "about apples")
        try box.file("a/.cache/report.txt", "about apples")
        try box.file("b/report.txt", "about pears")
        let fileSystems = makeFileSystems().0
        let paths =
            ["a/deep/report.txt", "a/report.txt", "a/notes.md", "a/.cache/report.txt", "b/report.txt", "a/gone.txt"]
            .map { box.url($0).path }
            + ["/somewhere/else/report.txt"]
        func verified(_ change: (inout SearchQuery) -> Void) -> [String] {
            var query = SearchQuery(directory: box.url("a"), names: "*.txt", text: "apples")
            change(&query)
            let search = FileSearch(query, fileSystems: fileSystems)
            return SpotlightQuery.verify(paths, with: search, fileSystems: fileSystems)
                .map {
                    String($0.url.path.dropFirst(box.root.path.count + 1))
                }
        }
        #expect(verified { _ in } == ["a/deep/report.txt", "a/report.txt"])
        #expect(verified { $0.maxDepth = 0 } == ["a/report.txt"])
        #expect(verified { $0.includeHidden = true } == ["a/.cache/report.txt", "a/deep/report.txt", "a/report.txt"])
        #expect(
            verified { $0.moreDirectories = [box.url("b")] } == ["a/deep/report.txt", "a/report.txt", "b/report.txt"]
        )
        // A text the index cannot answer is read from the files.
        #expect(
            verified {
                $0.moreDirectories = [box.url("b")]
                $0.text = "p[e]ars"
                $0.textOptions.regex = true
            } == ["b/report.txt"]
        )
        #expect(verified { $0.criteria.size = SizeRule(.greater, 100) }.isEmpty)
    }
}

/// The window driven without being shown: its form, a search from start to finish, and what
/// the buttons below the list do.
@MainActor @Suite struct FindFilesWindow {
    final class Lists: FileListService {
        var shown: [(files: [URL], title: String, panel: any PanelHandle)] = []
        func show(_ files: [URL], title: String, in panel: any PanelHandle) { shown.append((files, title, panel)) }
    }

    let memory = MemoryFileSystem()
    let plugin = FindFilesPlugin()
    let bench: TestBench
    var window: FindFilesWindowController { plugin.mainWindow(in: bench.kernel) }

    init() {
        memory.addFile("/A/one.txt", "first report")
        memory.addFile("/A/two.txt", "second")
        memory.addFile("/A/docs/one.txt", "first report")
        memory.addFile("/A/docs/three.md", "third report")
        memory.addFile("/B/x.txt", "x")
        bench = TestBench(
            plugins: [plugin],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
    }

    /// Fills the form like a user, runs the search and waits for its end.
    func search(_ change: (inout SearchSettings) -> Void) async {
        let window = window
        window.prepare(startingIn: bench.left.model.directory, includeHidden: false)
        var settings = window.form.settings
        change(&settings)
        window.form.settings = settings
        window.startSearch()
        for _ in 0..<2_000 where window.isSearching { try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    @Test func registersCommandsMenusAndPreferences() {
        #expect(bench.commands[.searchFor]?.title == "Find Files…" && bench.commands["cm_SearchStandalone"] != nil)
        #expect(bench.kernel.keyBindings.command(for: .f(7, .option)) == .searchFor)
        #expect(bench.kernel.keyBindings.command(for: .f(7, [.option, .shift])) == "cm_SearchStandalone")
        #expect(bench.kernel.keyClashes.isEmpty)
        #expect(bench.kernel.toolbar.defaultLayout.contains { $0?.command == .searchFor })
        #expect(bench.kernel.preferences.pages.map(\.title) == ["Find Files"])
        #expect(!bench.commands.isEnabled("cm_SearchForInCurDir"))
        bench.left.moveCursor(toName: "docs")
        #expect(bench.commands.isEnabled("cm_SearchForInCurDir"))
    }

    @Test func theFormGivesBackWhatItWasGiven() {
        var settings = SearchSettings()
        (
            settings.searchFor, settings.searchIn, settings.namesAreRegex, settings.searchArchives,
            settings.useSpotlight
        ) = ("a.*", "/x;/y", true, true, true)
        (settings.depth, settings.findText, settings.text, settings.caseSensitive) = (2, true, "needle", true)
        settings.textOptions = TextSearchOptions(
            wholeWords: true,
            regex: true,
            notContaining: true,
            encodings: [.utf8, .utf16]
        )
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        settings.criteria = FileCriteria(
            dateFrom: day,
            dateTo: day.addingTimeInterval(86_399),
            notOlderThan: Age(3, .weeks),
            olderThan: Age(2, .hours),
            size: SizeRule(.greater, 1.5, .megabytes)
        )
        (settings.criteria.hidden, settings.criteria.directory, settings.criteria.executable) = (.yes, .no, .yes)
        settings.duplicates = DuplicateOptions(isEnabled: true, sameName: false, sameSize: true, sameContents: true)
        settings.fieldRules = FieldRules(
            isEnabled: true,
            matchAll: false,
            rules: [FieldRule("tc.size", .greater, "10"), FieldRule("tc.name", .regex, "^a")]
        )
        window.form.settings = settings
        #expect(window.form.settings == settings)
        window.form.settings = SearchSettings()
        #expect(window.form.settings == SearchSettings())
    }

    @Test func aSearchListsItsHitsUnderASummary() async {
        await search { $0.searchFor = "*.txt" }
        #expect(
            window.lines == [
                "[3 files and 0 directories found]", "mem:/A/one.txt", "mem:/A/two.txt", "mem:/A/docs/one.txt"
            ]
        )
        await search { $0.searchFor = "docs zzz" }
        #expect(window.lines == ["[0 files and 1 directories found]", "mem:/A/docs"])
        await search { $0.searchFor = "nothing-like-this" }
        #expect(window.lines == ["[No files found]"] && window.resultItems.isEmpty)
        // The fields went into their histories, in the plugin's settings.
        #expect(
            SearchStore(settings: bench.kernel.settings).history(.searchFor) == [
                "nothing-like-this", "docs zzz", "*.txt"
            ]
        )
    }

    @Test func textAndDepthComeFromTheForm() async {
        await search { ($0.findText, $0.text) = (true, "REPORT") }
        #expect(window.resultItems.map(\.url.path) == ["/A/one.txt", "/A/docs/one.txt", "/A/docs/three.md"])
        await search { ($0.findText, $0.text, $0.depth) = (true, "report", 0) }
        #expect(window.resultItems.map(\.url.path) == ["/A/one.txt"])
        await search { ($0.findText, $0.text, $0.searchIn) = (true, "x", "mem:/B;mem:/A/docs") }
        #expect(window.resultItems.map(\.url.path) == ["/B/x.txt"])
    }

    @Test func duplicatesAreListedInGroups() async {
        memory.addFile("/A/docs/two.txt", "second")
        await search { $0.duplicates = DuplicateOptions(isEnabled: true, sameContents: true) }
        // The files of a group are in the order of their full paths.
        #expect(
            window.lines == [
                "[4 files and 0 directories found]", "one.txt  -  mem:/A/docs/", "one.txt  -  mem:/A/",
                String(repeating: "- ", count: 40), "two.txt  -  mem:/A/docs/", "two.txt  -  mem:/A/"
            ]
        )
        #expect(window.copyText.components(separatedBy: "\n")[3].isEmpty)
    }

    @Test func aFormThatCannotBeSearchedWithIsReported() async {
        await search { ($0.findText, $0.text, $0.textOptions.hex) = (true, "xyz", true) }
        #expect(
            bench.interaction.log == ["inform: The search cannot start"] && !window.isSearching && window.lines.isEmpty
        )
    }

    @Test func onlySelectedItemsOfThePanel() async {
        bench.left.model.select(mask: "docs two.txt")
        await search { ($0.searchFor, $0.onlySelected) = ("*.txt", true) }
        #expect(window.resultItems.map(\.url.path) == ["/A/two.txt", "/A/docs/one.txt"])
    }

    @Test func goToFilePutsThePanelOnTheResult() async {
        let navigation = bench.kernel.commands
        var went: [URL] = []
        navigation.register(
            Command(.changeDirectory, "cd"),
            parameterized: { argument in went += [argument.location].compactMap { $0 } }
        )
        await search { $0.searchFor = "three" }
        // The only result is taken although the summary line could be the selected one.
        window.goToFile()
        #expect(went == [memory.url("/A/docs/three.md")])
    }

    @Test func feedToListboxHandsTheResultsToTheListService() async {
        await search { $0.searchFor = "one" }
        // Without a plugin that shows lists, nothing happens.
        window.feedToListbox()
        #expect(window.resultItems.count == 2)
        let lists = Lists()
        bench.kernel.services.register((any FileListService).self, lists)
        bench.right.focus()
        window.feedToListbox()
        #expect(
            lists.shown.count == 1 && lists.shown[0].title == "Search result" && lists.shown[0].panel === bench.right
        )
        #expect(lists.shown[0].files == [memory.url("/A/one.txt"), memory.url("/A/docs/one.txt")])
        // Fed results are not kept in the window.
        #expect(window.lines.isEmpty)
    }

    @Test func newSearchEmptiesTheList() async {
        await search { $0.searchFor = "one" }
        window.newSearch()
        #expect(window.lines.isEmpty && window.form.settings.searchFor == "one")
    }
}

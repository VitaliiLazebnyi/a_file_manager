import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FindFilesPlugin

/// Questions to Spotlight's index and the check of its answers.
@Suite
internal struct SpotlightQueries {
    /// A search of `/Users/x` for the names `names` and the text `text`.
    internal func query(names: String, text: String) -> SearchQuery {
        SearchQuery(directory: URL(fileURLWithPath: "/Users/x"), names: names, text: text)
    }

    /// Masks and text become a question in Spotlight's language, with what it must escape.
    @Test
    internal func questionsInSpotlightsLanguage() {
        #expect(SpotlightQuery.string(for: query(names: "", text: "")) == "kMDItemFSName == \"*\"")
        #expect(
            SpotlightQuery.string(for: query(names: "*.txt report | *.bak", text: ""))
                == "(kMDItemFSName == \"*.txt\"c || kMDItemFSName == \"*report*\"c) && kMDItemFSName != \"*.bak\"c"
        )
        #expect(
            SpotlightQuery.string(for: query(names: "file_??.txt", text: "")) == "(kMDItemFSName == \"file_**.txt\"c)"
        )
        #expect(SpotlightQuery.string(for: query(names: "*.* | a\\b", text: "")) == "kMDItemFSName != \"*a\\\\b*\"c")
        #expect(
            SpotlightQuery.string(for: query(names: "", text: "50* off")) == "kMDItemTextContent == \"*50\\* off*\"cd"
        )
        var sensitive = query(names: "*.md", text: "Smith")
        sensitive.caseSensitive = true
        sensitive.textOptions.wholeWords = true
        #expect(
            SpotlightQuery.string(for: sensitive) == "(kMDItemFSName == \"*.md\"c) && kMDItemTextContent == \"Smith\"w"
        )
    }

    /// Sizes and dates become comparisons of the index's attributes.
    @Test
    internal func sizesAndDates() {
        var sized = query(names: "", text: "")
        sized.criteria.size = SizeRule(.equal, 2, .kilobytes)
        sized.criteria.dateFrom = Date(timeIntervalSince1970: 0)
        sized.criteria.olderThan = Age(1, .hours)
        let now = Date(timeIntervalSince1970: 7_200)
        #expect(
            SpotlightQuery.string(for: sized, now: now)
                == "(kMDItemFSSize >= 2048 && kMDItemFSSize < 3072)"
                + " && kMDItemFSContentChangeDate >= $time.iso(1970-01-01T00:00:00Z)"
                + " && kMDItemFSContentChangeDate < $time.iso(1970-01-01T01:00:00Z)"
        )
        sized.criteria = FileCriteria(size: SizeRule(.greater, 1.5, .megabytes))
        #expect(SpotlightQuery.string(for: sized) == "kMDItemFSSize > 1572864")
    }

    /// Every question made can be read by the system.
    @Test
    internal func spotlightUnderstandsEveryQuestion() {
        var full = query(names: "*.txt \"my file.doc\" | *.bak a\"b", text: "a \"quoted\" \\ text*")
        full.criteria = FileCriteria(
            dateFrom: Date(),
            dateTo: Date(),
            notOlderThan: Age(3, .days),
            olderThan: Age(1, .minutes),
            size: SizeRule(.less, 0.5, .gigabytes)
        )
        for query in [query(names: "", text: ""), query(names: "report", text: ""), full] {
            #expect(NSPredicate(fromMetadataQueryString: SpotlightQuery.string(for: query)) != nil)
        }
    }

    /// Expressions and "NOT containing" are left to the search; servers and chosen items are not asked.
    @Test
    internal func whatTheIndexCannotAnswerIsLeftToTheSearch() throws {
        var regex = query(names: "^a", text: "x+")
        regex.namesAreRegex = true
        regex.textOptions.regex = true
        #expect(SpotlightQuery.string(for: regex) == "kMDItemFSName == \"*\"" && !SpotlightQuery.handlesText(of: regex))
        var not = query(names: "", text: "x")
        #expect(SpotlightQuery.handlesText(of: not))
        not.textOptions.notContaining = true
        #expect(!SpotlightQuery.handlesText(of: not) && !SpotlightQuery.handlesText(of: query(names: "", text: "")))
        #expect(SpotlightQuery.isAvailable(for: query(names: "", text: "")))
        var remote = query(names: "", text: "")
        remote.moreDirectories = [try #require(URL(string: "mem:///x"))]
        #expect(!SpotlightQuery.isAvailable(for: remote))
        var chosen = query(names: "", text: "")
        chosen.scope = .only([])
        #expect(!SpotlightQuery.isAvailable(for: chosen))
    }

    /// The paths the index returns are checked against the place, depth, hidden files and criteria.
    @Test
    internal func answersAreCheckedAgainstTheWholeSearch() throws {
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
                .map { item in
                    String(item.url.path.dropFirst(box.root.path.count + 1))
                }
        }
        #expect(
            verified { _ in
                // The search as it is.
            } == ["a/deep/report.txt", "a/report.txt"]
        )
        #expect(verified { $0.maxDepth = 0 } == ["a/report.txt"])
        #expect(verified { $0.includeHidden = true } == ["a/.cache/report.txt", "a/deep/report.txt", "a/report.txt"])
        #expect(
            verified { $0.moreDirectories = [box.url("b")] } == ["a/deep/report.txt", "a/report.txt", "b/report.txt"]
        )
        // A text the index cannot answer is read from the files.
        #expect(
            verified { query in
                query.moreDirectories = [box.url("b")]
                query.text = "p[e]ars"
                query.textOptions.regex = true
            } == ["b/report.txt"]
        )
        #expect(verified { $0.criteria.size = SizeRule(.greater, 100) }.isEmpty)
    }
}

import AFMKernel
import Foundation
import Testing

@testable import AFMShell

/// Finding a file by typing the start of its name (spec 03 › Quick search): which row the
/// cursor goes to, and the quick comparison of names.
@MainActor
@Suite
internal struct PanelTypeSelectTests {
    /// Entries of these names.
    private func items(_ names: [String]) -> [FileItem] {
        names.map { FileItem(url: URL(fileURLWithPath: "/x/" + $0), name: $0) }
    }

    /// The row of the next entry that starts with `prefix`, from `cursor`.
    private func row(_ prefix: String, in names: [String], from cursor: Int) -> Int? {
        TypeSelect.row(matching: prefix, in: items(names), from: cursor, cancellation: nil)
    }

    /// The same letter again moves on to the next name with it; a longer prefix may stay.
    @Test
    internal func typingFindsTheNextNameWithThatStart() {
        let names = ["alpha", "beta", "Bravo", "report_01", "report_02"]
        #expect(row("b", in: names, from: 0) == 1)
        #expect(row("b", in: names, from: 1) == 2 && row("b", in: names, from: 2) == 1)
        #expect(row("rep", in: names, from: 3) == 3 && row("report_02", in: names, from: 3) == 4)
        #expect(
            row("x", in: names, from: 0) == nil && row("a", in: [], from: 0) == nil
                && row("", in: names, from: 0) == nil
        )
        // From the `[..]` row, which is before the first name.
        #expect(row("a", in: names, from: -1) == 0)
    }

    /// What was typed is forgotten after a pause of more than a second.
    @Test
    internal func whatWasTypedIsForgottenAfterAPause() {
        var typing = TypeSelect()
        #expect(typing.add("r", at: 10) == "r" && typing.add("e", at: 10.4) == "re")
        #expect(typing.add("n", at: 12) == "n")
    }

    /// The byte by byte comparison of ASCII text agrees with Foundation's for every kind of name.
    @Test
    internal func theQuickComparisonOfNamesAgreesWithFoundation() {
        let names = [
            "Report.txt", "report_02.TXT", "re", "", "Résumé.doc", "re\u{301}sume", "ß-file", "ALPHA", "alpha beta",
            "über", "日本語", "a\u{308}b", "ab\u{301}", "r"
        ]
        for prefix in ["r", "RE", "rep", "report_02.txt", "a", "al", "alpha b", "ü", "é", "res", "日", "ab", " "] {
            let matches = TypeSelect.matcher(for: prefix)
            for name in names {
                #expect(
                    matches(name) == (name.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil),
                    "\(prefix) in \(name)"
                )
            }
        }
        #expect(row("al", in: names, from: 0) == 7 && row("a", in: names, from: 7) == 8)
        #expect(row("zz", in: names, from: 3) == nil)
    }

    /// A long list is looked through until the search is given up.
    @Test
    internal func aSearchThatIsGivenUpEndsWithNothing() {
        let cancelled = CancellationFlag()
        cancelled.cancel()
        let long = items((0..<10_000).map { "n\($0)" })
        #expect(TypeSelect.row(matching: "zz", in: long, from: 0, cancellation: cancelled) == nil)
        #expect(TypeSelect.row(matching: "n9999", in: long, from: 0, cancellation: CancellationFlag()) == 9_999)
    }
}

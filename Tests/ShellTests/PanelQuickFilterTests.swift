import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import AFMShell

/// The quick filter by itself (spec 03 › Quick filter): how typed text is compared with names,
/// when it narrows what is shown, and how it lies over the display filter.
@MainActor
@Suite
internal struct PanelQuickFilterTests {
    /// An entry called `name`, a folder when `folder` says so.
    private func item(_ name: String, folder: Bool) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/x/" + name), name: name, kind: .init(isDirectory: folder))
    }

    /// Text is a part of a name; with `*` or `?` it is a mask.
    ///
    /// Case does not matter.
    @Test
    internal func theQuickFilterMatchesPartsOfNamesOrMasks() {
        let part = QuickFilter.matcher(for: "Port")
        #expect(part("report.txt") && part("PORTS") && !part("notes.txt"))
        let mask = QuickFilter.matcher(for: "*.TXT")
        #expect(mask("a.txt") && !mask("a.txt.bak"))
        let single = QuickFilter.matcher(for: "r?p*")
        #expect(single("report") && !single("grep"))
        let accented = QuickFilter.matcher(for: "Üb")
        #expect(accented("übung") && !accented("ubung"))
    }

    /// The byte by byte comparison of plain text agrees with Foundation for every kind of name.
    @Test
    internal func theQuickFilterOfPlainTextAgreesWithFoundationForEveryKindOfName() {
        let names = [
            "report.txt", "REPORT.TXT", "Übung.txt", "ÜBUNG", "naïve cafe", "café", "K.txt", "\u{212A}elvin", "日本語.md",
            "a", "", "ab", "tx"
        ]
        for text in ["Port", "t", "txt", "ung", "ÜB", "café", "k", "日本", "xt", "ab", "TX"] {
            let matches = QuickFilter.matcher(for: text)
            for name in names {
                #expect(
                    matches(name) == (name.range(of: text.lowercased(), options: .caseInsensitive) != nil),
                    "\(text) in \(name)"
                )
            }
        }
    }

    /// Only text typed on (plain text, the old within the new) narrows the list that is shown.
    @Test
    internal func onlyTextTypedOnIsTakenToNarrowTheList() {
        #expect(QuickFilter.narrows(from: "re", to: "rep") && QuickFilter.narrows(from: "re", to: "xre"))
        #expect(QuickFilter.narrows(from: "Re", to: "rEp"))
        // Fewer letters, other letters, a mask, or no text before: the whole list is filtered again.
        #expect(!QuickFilter.narrows(from: "rep", to: "re") && !QuickFilter.narrows(from: "re", to: "ro"))
        #expect(!QuickFilter.narrows(from: "", to: "a") && !QuickFilter.narrows(from: "re", to: "re*"))
        #expect(!QuickFilter.narrows(from: "r?", to: "r?a") && !QuickFilter.narrows(from: "*", to: "*a"))
        #expect(!QuickFilter.narrows(from: "ü", to: "üb") && !QuickFilter.narrows(from: "u", to: "uü"))
        // The narrowed list is the one the full filter gives, over the names that make a trap of "contains".
        let names = ["report.txt", "Reprint", "bare", "a.rep", "REP", "", "r", "xrex", "Übung", "ré"]
        for (old, new) in [("r", "re"), ("re", "rep"), ("e", "re"), ("p", "rep")] {
            let before = names.filter(QuickFilter.matcher(for: old))
            #expect(QuickFilter.narrows(from: old, to: new))
            #expect(before.filter(QuickFilter.matcher(for: new)) == names.filter(QuickFilter.matcher(for: new)))
        }
    }

    /// The quick filter shows what passes both it and the display filter below, and is named
    /// after both.
    @Test
    internal func theQuickFilterLiesOverTheDisplayFilter() throws {
        let base = PanelFilter.mask("*.txt")
        var filter = QuickFilter(text: "", base: base, directory: URL(fileURLWithPath: "/x"))
        #expect(filter.combined?.title == "*.txt" && filter.title == "*.txt")
        filter.text = "re"
        #expect(filter.title.hasPrefix("*.txt") && filter.title.hasSuffix("re"))
        let combined = try #require(filter.combined)
        #expect(
            combined.matches(item("report.txt", folder: false)) && !combined.matches(item("report.pdf", folder: false))
        )
        #expect(!combined.matches(item("notes.txt", folder: false)))
        // Folders are filtered by name too; the display filter below lets them all through.
        #expect(combined.matches(item("recent", folder: true)) && !combined.matches(item("docs", folder: true)))
        #expect(QuickFilter(text: "", base: nil, directory: URL(fileURLWithPath: "/x")).combined == nil)
        let alone = QuickFilter(text: "re", base: nil, directory: URL(fileURLWithPath: "/x"))
        #expect(alone.title == "⏷ re" && alone.combined?.matches(item("ready", folder: false)) == true)
    }

    /// A name that comes from Foundation without bytes of its own to look at (as the names of a
    /// folder of the disk do) is compared by Foundation.
    @Test
    internal func aNameWithoutBytesOfItsOwnIsComparedByFoundation() throws {
        let box = try Sandbox()
        try box.file("Report.txt")
        let listed = try FileManager.default.contentsOfDirectory(at: box.root, includingPropertiesForKeys: nil)
        let name = try #require(listed.first?.lastPathComponent)
        #expect(name.utf8.withContiguousStorageIfAvailable { $0.count } == nil)
        #expect(QuickFilter.matcher(for: "PORT")(name) && !QuickFilter.matcher(for: "rx")(name))
    }
}

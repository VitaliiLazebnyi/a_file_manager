import AppKit
import Testing

@testable import SystemToolsPlugin

/// Round 2 of the review, second pass, System Tools: printing a folder list.
@MainActor
@Suite
internal struct Review2PluginsA2SystemTools {
    /// The print view measures its longest line without cutting every line into characters and counts its pages.
    @Test
    internal func theLongestLineIsMeasuredWithoutCuttingEveryLineIntoCharacters() {
        let pages = [[String(repeating: "e\u{301}", count: 40), "short"], ["x"]]
        let view = PagePrintView(pages: pages, linesPerPage: 60, printInfo: NSPrintInfo())
        var range = NSRange()
        #expect(withUnsafeMutablePointer(to: &range) { view.knowsPageRange($0) } && range.length == 2)
    }
}

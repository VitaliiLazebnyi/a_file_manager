import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FolderTabsPlugin

/// The tab file format beyond the other suites: values with escapes, files with damaged
/// escapes, locations that cannot be read and bytes that are not text.
@Suite
internal struct CoverageFolderTabsFile {
    /// Where the tabs of the files point.
    private let memory = MemoryFileSystem()

    /// A file read with the memory file system's locations.
    private func read(_ text: String) -> TabFile? {
        TabFile(text: text) { memory.location(from: $0) }
    }

    /// Every character a value can hold is written so that it reads back the same.
    @Test
    internal func valuesWithEscapesReadBackTheSame() {
        let text = "a\\b \"c\"\rd\te\u{1}f\u{2028}g\nh"
        let value = TabFile.value(text)
        #expect(value == "\"a\\\\b \\\"c\\\"\\rd\\te\\u{1}f\\u{2028}g\\nh\"")
        #expect(TabFile.unquoted(value) == text)
        #expect(TabFile.value("plain") == "plain" && TabFile.unquoted("plain") == "plain")
    }

    /// A quoted value with an escape that is not ours, or a quote inside, is taken as it is.
    @Test
    internal func damagedEscapesAreTakenAsTheyAre() {
        for damaged in [
            "\"a\"b\"", "\"a\\\"", "\"\\q\"", "\"\\u41\"", "\"\\u{41\"", "\"\\u{}\"", "\"\\u{zz}\"",
            "\"\\u{1234567}\"", "\"\\u{D800}\""
        ] {
            #expect(TabFile.unquoted(damaged) == damaged, "\(damaged)")
        }
        #expect(TabFile.unquoted("\"\\u{41}\\u{42}\"") == "AB")
    }

    /// A tab whose location is no URL is written as it is.
    @Test
    internal func aLocationThatIsNoURLIsWrittenAsItIs() {
        var tab = PanelTabState(location: memory.url("/A"))
        tab.location = ""
        let text = TabFile(active: PanelTabs.State(tabs: [tab], active: 0)).text(displayPath: memory.displayPath)
        #expect(text.hasPrefix("[activetabs]\n0_path=\n"))
    }

    /// Bytes with the mark of UTF-16 that are no UTF-16 are read as UTF-8 as far as they go.
    @Test
    internal func brokenUTF16IsReadAsUTF8() {
        #expect(TabFile.text(decoding: Data([0xFF, 0xFE, 0x00, 0xD8])) == "\u{FFFD}\u{FFFD}\u{0}\u{FFFD}")
    }

    /// An empty caption, or one longer than the limit, gives the tab no title.
    @Test
    internal func emptyAndOverlongCaptionsAreDropped() {
        let long = String(repeating: "x", count: TabFile.captionLimit + 1)
        let file = read("[activetabs]\n0_path=mem:/A\n0_caption=\n1_path=mem:/B\n1_caption=\(long)\n")
        #expect(file?.active.tabs.map(\.title) == [nil, nil])
    }
}

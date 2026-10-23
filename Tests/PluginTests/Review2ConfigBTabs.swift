import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FolderTabsPlugin

/// Tab files (review 2): line breaks, encodings, old files and limits.
@Suite
internal struct Review2ConfigBTabs {
    /// The file system the tabs' locations are on.
    internal let memory = MemoryFileSystem()

    /// The tab file `text` holds, its locations read on `memory`; nil when it is none.
    internal func read(_ text: String) -> TabFile? { TabFile(text: text) { memory.location(from: $0) } }

    /// Paths and captions with line breaks come back as they were and start no line of their own.
    @Test
    internal func pathsAndCaptionsWithLineBreaksRoundTripWithoutInjectingLines() throws {
        let awkward = memory.url("/tmp/a\n1_path=sftp://evil.example/x")
        let tab = PanelTabState(location: awkward, title: "t\n1_path=/etc")
        let file = TabFile(
            active: PanelTabs.State(
                tabs: [tab, PanelTabState(location: memory.url("/second"), title: " padded ")],
                active: 0
            )
        )
        let text = file.text(displayPath: memory.displayPath)
        // No line of the file starts a tab of its own that was not written as one.
        #expect(
            !text.split(whereSeparator: \.isNewline)
                .contains { line in
                    line.hasPrefix("1_path=sftp") || line.hasPrefix("1_path=/etc")
                }
        )
        let back = try #require(read(text))
        #expect(back == file)
        #expect(
            back.active.tabs.count == 2 && back.active.tabs[0].title == "t\n1_path=/etc"
                && back.active.tabs[1].title == " padded "
        )
    }

    /// Files with a byte order mark and files in UTF-16 are read.
    @Test
    internal func aByteOrderMarkAndUTF16FilesAreRead() throws {
        #expect(read("\u{FEFF}[activetabs]\n0_path=mem:/A\n")?.active.tabs.count == 1)
        let utf16 = try #require("[activetabs]\r\n0_path=mem:/A\r\n".data(using: .utf16))
        #expect(read(TabFile.text(decoding: utf16))?.active.tabs.count == 1)
        let utf8 = Data([0xEF, 0xBB, 0xBF]) + Data("[activetabs]\n0_path=mem:/B\n".utf8)
        #expect(read(TabFile.text(decoding: utf8))?.active.tabs.count == 1)
    }

    /// Old tab files with backslashes are read as they stand.
    @Test
    internal func oldTabFilesWithBackslashesAreReadAsTheyStand() {
        let file = read("[activetabs]\n0_path=mem:/C:\\dir\n0_caption=C:\\Work\n")
        #expect(file?.active.tabs.first?.title == "C:\\Work")
    }

    /// A tab file opens no more than the limit of tabs, and no path that is too long.
    @Test
    internal func aTabFileOpensNoMoreThanTheLimit() throws {
        let lines = (0..<5_000).map { "\($0)_path=mem:/d\($0)" }.joined(separator: "\n")
        let file = try #require(read("[activetabs]\n" + lines + "\n"))
        #expect(file.active.tabs.count == TabFile.tabLimit)
        let huge = String(repeating: "x", count: TabFile.pathLimit + 1)
        #expect(read("[activetabs]\n0_path=mem:/\(huge)\n") == nil)
    }
}

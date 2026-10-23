import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FolderTabsPlugin

/// Tab files written and read back, also as people write them by hand.
@Suite
internal struct TabFiles {
    /// The file system the tabs' locations belong to.
    internal let memory = MemoryFileSystem()

    /// The tab file a text holds, its paths read by the memory file system.
    internal func read(_ text: String) -> TabFile? {
        TabFile(text: text) { path in memory.location(from: path) }
    }

    /// Both sides are written in the INI form and read back the same.
    @Test
    internal func writesAndReadsBothSides() {
        let active = PanelTabs.State(
            tabs: [
                .init(location: memory.url("/A"), title: "Work", locked: true),
                .init(
                    location: memory.url("/A/my docs"),
                    order: ListOrder(key: .date, descending: true),
                    showHidden: true
                )
            ],
            active: 1
        )
        let inactive = PanelTabs.State(tabs: [.init(location: memory.url("/B"))], active: 0)
        let text = TabFile(active: active, inactive: inactive).text(displayPath: memory.displayPath)
        #expect(
            text == """
                [activetabs]
                0_path=mem:/A
                0_caption=Work
                0_options=1|0|0|0|0|1|0
                1_path=mem:/A/my docs
                1_options=1|3|1|0|0|0|1
                activetab=1

                [inactivetabs]
                0_path=mem:/B
                0_options=1|0|0|0|0|0|0
                activetab=0

                """
        )
        #expect(read(text) == TabFile(active: active, inactive: inactive))
        #expect(read(TabFile(active: inactive).text(displayPath: memory.displayPath)) == TabFile(active: inactive))
    }

    /// A file written by hand, with unknown keys and unreadable paths, gives the tabs it can.
    @Test
    internal func readsHandWrittenAndDamagedFiles() throws {
        let file = try #require(
            read(
                "; my tabs\r\n[ActiveTabs]\r\n3_path=mem:/C\r\n1_path=mem:/A\r\n2_path=elsewhere\r\n"
                    + "activetab=3\r\nunknown=1\r\n"
            )
        )
        #expect(file.active.tabs.map(\.location) == [memory.url("/A").absoluteString, memory.url("/C").absoluteString])
        #expect(file.active.active == 1 && file.inactive == nil)
        #expect(
            file.active.tabs[0].title == nil && !file.active.tabs[0].locked && !file.active.tabs[0].showHidden
        )
        #expect(read("") == nil && read("[activetabs]\nactivetab=0\n") == nil)
        // A file with only the other side's section still gives tabs.
        #expect(read("[inactivetabs]\n0_path=mem:/B\n")?.active.tabs.count == 1)
    }
}

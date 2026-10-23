import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FolderTabsPlugin

/// Tab files loaded into a panel (review 2): server tabs are not shown at once, and limits hold.
@MainActor
@Suite
internal struct Review2ConfigBTabLoading {
    /// The folders `/A` and `/B`, and the tab files.
    internal let memory = MemoryFileSystem()
    /// The program with folder tabs, `/A` on the left and `/B` on the right, and two server schemes.
    internal let bench: TestBench

    /// The bench over the two folders.
    internal init() {
        memory.addFile("/A/one.txt")
        memory.addFile("/B/other.txt")
        bench = TestBench(
            plugins: [FolderTabsPlugin()],
            fileSystems: [
                memory, Review2WatchFileSystem(scheme: "sftp"), Review2WatchFileSystem(scheme: "ftp")
            ],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
    }

    /// Loading a tab file never makes a tab on a server the one shown.
    @Test
    internal func loadingAFileNeverMakesAServerTabTheShownOne() {
        memory.addFile(
            "/B/tabs.tab",
            "[activetabs]\n0_path=mem:/A\n1_path=sftp://evil.example/x\n2_path=mem:/B\nactivetab=1\n"
        )
        bench.commands.perform("OPENTABS", .location(memory.url("/B/tabs.tab")))
        let tabs = bench.left.tabs
        #expect(tabs.count == 3)
        #expect(tabs.active.directory.scheme == "mem")
        #expect(tabs.tabs[1].directory.scheme == "sftp")
    }

    /// A file whose tabs are all on servers adds them and leaves the shown tab alone.
    @Test
    internal func aFileWhoseTabsAllConnectLeavesTheShownTabAlone() {
        memory.addFile(
            "/B/tabs.tab",
            "[activetabs]\n0_path=sftp://evil.example/x\n1_path=ftp://other.example/y\nactivetab=0\n"
        )
        bench.commands.perform("OPENTABS", .location(memory.url("/B/tabs.tab")))
        let tabs = bench.left.tabs
        #expect(tabs.active.directory == memory.url("/A") && tabs.count == 3)
        #expect(tabs.tabs.contains { $0.directory.scheme == "sftp" })
    }

    /// Loading many tabs tells the panel's listener once.
    @Test
    internal func loadingManyTabsTellsTheListenerOncePerPanel() {
        let lines = (0..<100).map { "\($0)_path=mem:/A/d\($0)" }.joined(separator: "\n")
        memory.addFile("/B/many.tab", "[activetabs]\n" + lines + "\nactivetab=3\n")
        var changes = 0
        bench.left.tabs.onChange = { changes += 1 }
        bench.commands.perform("OPENTABS", .location(memory.url("/B/many.tab")))
        #expect(bench.left.tabs.count == 100 && changes == 1)
    }

    /// A file with thousands of tabs opens no more than the limit per panel.
    @Test
    internal func aFileWithThousandsOfTabsOpensTheLimit() {
        let lines = (0..<3_000).map { "\($0)_path=mem:/A/d\($0)" }.joined(separator: "\n")
        memory.addFile("/B/huge.tab", "[activetabs]\n" + lines + "\n")
        bench.commands.perform("APPENDTABS", .location(memory.url("/B/huge.tab")))
        #expect(bench.left.tabs.count <= FolderTabsPlugin.tabsPerPanelLimit)
    }
}

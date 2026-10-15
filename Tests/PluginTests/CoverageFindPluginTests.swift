import AFMContracts
import AFMKernel
import AppKit
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FindFilesPlugin

/// Find Files through its commands, as the program opens it: the one window, the separate ones,
/// the folder under the cursor and a volume that is about to go. The windows are presented to a
/// recorder, never put on screen.
@MainActor @Suite(.serialized) struct CoverageFindPlugin {
    let memory = MemoryFileSystem()
    let plugin = FindFilesPlugin()
    let bench: TestBench
    let presenter = StabilityPresenter()

    init() {
        _ = NSApplication.shared
        memory.addFile("/A/one.txt")
        memory.addDirectory("/A/docs")
        bench = TestBench(
            plugins: [plugin],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/A")
        )
        plugin.present = presenter.present
    }

    var windows: [NSWindow] { presenter.open.filter { $0.title.hasPrefix("Find Files") } }

    @Test func theCommandsOpenTheirWindows() {
        defer {
            plugin.stop()
            presenter.closeAll()
        }
        #expect(bench.commands.perform(.searchFor, .location(memory.url("/A/docs"))))
        #expect(
            plugin.mainWindow(in: bench.kernel).form.settings.searchIn
                == bench.kernel.fileSystems.displayPath(memory.url("/A/docs"))
        )
        #expect(bench.commands.perform(.searchFor))
        #expect(bench.commands.perform("cm_SearchStandalone"))
        #expect(bench.commands.perform("cm_SearchStandalone"))
        #expect(windows.count == 3 && presenter.presented.count == 4)
        // A separate window that is closed is let go of.
        windows.first { $0.title == "Find Files (separate)" }?.close()
        #expect(windows.count == 2)
        bench.left.moveCursor(toName: "docs")
        #expect(bench.commands.perform("cm_SearchForInCurDir"))
        #expect(presenter.presented.count == 5)
        plugin.stop()
        #expect(windows.isEmpty)
    }

    @Test func aVolumeAboutToGoStopsTheSearchesOnIt() async {
        defer {
            plugin.stop()
            presenter.closeAll()
        }
        memory.stallsListings = true
        defer { memory.stallsListings = false }
        let main = plugin.mainWindow(in: bench.kernel)
        main.prepare(startingIn: memory.url("/A"), includeHidden: false)
        var settings = main.form.settings
        settings.searchIn = ""
        main.form.settings = settings
        main.startSearch()
        #expect(bench.commands.perform("cm_SearchStandalone"))
        bench.kernel.fileSystems.releaseVolume(URL(fileURLWithPath: "/Volumes/Gone"))
        #expect(await RunLoopWait.until { !main.isSearching })
    }
}

import AFMContracts
import AFMKernel
import AFMShell
import AppKit
import TestSupport
import Testing

@testable import ViewerPlugin

/// The pane over a file system that is slow: closing it, switching files and laying a big text
/// out again.
@MainActor @Suite(.serialized) struct ViewerAdoptPane {
    let memory = MemoryFileSystem()
    let plugin: ViewerPlugin
    let bench: TestBench

    init() {
        _ = NSApplication.shared
        plugin = ViewerPlugin(overlayHost: { _ in nil }, quickViewDelay: 0.01, showsWindows: false)
        plugin.mediaPlayback = CovViewPlayback.factory
        bench = TestBench(plugins: [plugin], fileSystems: [memory], left: memory.url("/A"), right: memory.url("/B"))
        memory.addFile("/A/small.txt", "small file\nsecond line")
    }

    @discardableResult
    func wait(upTo seconds: TimeInterval = Wait.ceiling, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
        return condition()
    }

    /// Whether everything the pane gave its work queue so far has ended.
    ///
    /// The main thread stays free meanwhile: the tests of other suites run their main-thread work
    /// on it.
    private func drained(_ pane: ViewerPane) async -> Bool {
        let done = Shared(false)
        pane.workQueue.async(flags: .barrier) { done.value = true }
        return await wait { done.value }
    }

    @Test func closingThePaneEndsAReadThatWaitsForTheServer() async throws {
        memory.addFile("/A/slow.txt", String(repeating: "a slow line\n", count: 20_000))
        memory.stallsReads = true
        defer { memory.releaseStalls() }
        plugin.view(memory.url("/A/slow.txt"))
        let controller = try #require(plugin.windows.last)
        let pane = controller.pane
        // Closing the window stops the work of the pane; a read that waits for the server is
        // interrupted, or the queue would never get to the end of it.
        pane.stopWork()
        #expect(await drained(pane), "the read of the file is still blocked")
        #expect(pane.loaded == nil)
    }

    @Test func switchingFilesInTheQuickViewDropsTheFileThatIsStillBeingRead() async {
        memory.addFile("/A/slow.txt", String(repeating: "a slow line\n", count: 20_000))
        memory.stallsReads = true
        defer { memory.releaseStalls() }
        let pane = ViewerPane(
            kernel: bench.kernel,
            settings: ListerSettings(bench.kernel.settings),
            temporaryCopies: TemporaryCopies(),
            isEmbedded: true
        )
        pane.load(ViewerItem(source: .file(memory.url("/A/slow.txt")), title: "slow"))
        // The cursor moves on: the next file is read, from a server that answers.
        memory.stallsReads = false
        pane.load(ViewerItem(source: .file(memory.url("/A/small.txt")), title: "small"))
        #expect(await wait { pane.loaded?.item.title == "small" })
        #expect(await drained(pane))
        #expect(await wait { !pane.pager.isIndexing && pane.pager.document?.rowCount == 2 })
        // Showing nothing (the cursor is on a folder) stops it just the same.
        memory.stallsReads = true
        pane.load(ViewerItem(source: .file(memory.url("/A/slow.txt")), title: "slow again"))
        pane.clear()
        #expect(await drained(pane))
        pane.stopWork()
    }

    @Test func aBigTextOfASlowFileSystemIsKeptOnDiskForTheNextLayout() async throws {
        // Above what is kept in memory (the pane's blocks are made small for the test, 1 MB in
        // all, as 64 MB are in the program); lines of about 25 bytes.
        let block = Data(String(repeating: "line of the big text\n", count: 5_000).utf8)
        var big = Data()
        while big.count < 3 << 19 { big.append(block) }
        let url = memory.url("/A/big.txt")
        let writer = try memory.write(url)
        try writer.write(big)
        try writer.close(attributes: FileAttributes())
        memory.isLocal = false
        let pane = ViewerPane(
            kernel: bench.kernel,
            settings: ListerSettings(bench.kernel.settings),
            temporaryCopies: TemporaryCopies(),
            isEmbedded: true
        )
        defer { pane.stopWork() }
        pane.slowFileBlocks = (size: 16 << 10, count: 64)
        pane.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        pane.load(ViewerItem(source: .file(url), title: "big"))
        #expect(await wait { pane.loaded != nil && pane.pager.document?.isIndexComplete == true })
        let source = try #require(pane.loaded?.source as? CachedByteSource)
        let first = try #require(pane.pager.document)
        #expect(
            source.diskCacheIsOpen && source.diskBytes >= source.length - 4 * 16 << 10,
            "\(source.diskBytes) of \(source.length) bytes on disk"
        )
        // Another width: the lines are short, so every segment of the first layout is taken over.
        bench.kernel.settings.set("100", forKey: "viewer.textWidth")
        pane.relayout()
        #expect(await wait { pane.pager.document !== first && pane.pager.document?.isIndexComplete == true })
        let second = try #require(pane.pager.document)
        #expect(second.segmentsReused > 0 && second.rowCount == first.rowCount)
        pane.stopWork()
        // The source is closed off the main thread.
        ViewerCleanup.drain()
        #expect(source.diskBytes == 0 && !source.diskCacheIsOpen)
    }
}

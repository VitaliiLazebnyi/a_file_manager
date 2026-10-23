import AFMContracts
import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import SelectionPlugin
import TestSupport
import Testing

@testable import ClipboardPlugin
@testable import FileOperationsPlugin

/// Second pass of review round 2 for the clipboard: long lists are made and read in the background or in slices
/// (F003, F039), and a text that cannot be pasted leaves nothing behind (F040).
@MainActor
@Suite
internal struct Review2FileopsP2ClipboardTests {
    /// The temporary folder on the local disk; the right panel shows its folder `t`.
    internal let box: Sandbox
    private let scratch = ScratchPasteboard()
    /// A pasteboard of the test's own, in place of the general one.
    internal var pasteboard: NSPasteboard { scratch.pasteboard }
    /// The file system the left panel shows: `/A` with one file.
    internal let probe = P2ProbeFileSystem()
    /// A kernel with the file operations, the clipboard and the selection.
    internal let bench: TestBench

    /// The kernel's commands.
    internal var commands: CommandRegistry { bench.commands }

    /// A sandbox, the probe and the kernel, with the left panel on `/A` and the right one on the sandbox's `t`.
    internal init() throws {
        box = try Sandbox()
        try box.folder("t")
        probe.base.addFile("/A/one.txt")
        bench = TestBench(
            plugins: [FileOperationsPlugin(), ClipboardPlugin(pasteboard: scratch.pasteboard), SelectionPlugin()],
            fileSystems: [LocalFileSystem(), probe],
            left: probe.base.url("/A"),
            right: box.url("t")
        )
    }

    /// Lets the main queue run until `condition` holds.
    ///
    /// The limit is far beyond what the work takes; it only ends a test whose condition never comes
    /// true.
    private func wait(for condition: () -> Bool) async -> Bool {
        for _ in 0..<12_000 {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    /// A long list of names is made in the background, and the latest request wins (F003).
    @Test
    internal func aLongListOfNamesIsMadeInTheBackgroundAndTheLatestRequestWins() async {
        let count = ClipboardPlugin.listedAtOnce + 50
        for index in 0..<count { probe.base.addFile("/long/f\(index).txt") }
        bench.left.show(probe.base.url("/long"))
        commands.perform(.selectAll)
        pasteboard.clearContents()
        commands.perform(ClipboardCommands.copyNames)
        // Not there yet: the text is being put together elsewhere.
        #expect(pasteboard.string(forType: .string) == nil)
        #expect(await wait { pasteboard.string(forType: .string) != nil })
        #expect(pasteboard.string(forType: .string)?.split(separator: "\n").count == count)
        // Asked for again, and something newer put on the clipboard before it arrived: the
        // long list must not take its place afterwards.
        commands.perform(ClipboardCommands.copyNames)
        commands.perform(ClipboardCommands.copySourcePath)
        #expect(pasteboard.string(forType: .string) == "probe:/long")
        // The list has long been put together by then (it takes a millisecond); had it been
        // handed over after all, it would be on the clipboard now.
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(pasteboard.string(forType: .string) == "probe:/long")
    }

    /// What another program does: one pasteboard item per file.
    private func writeAsAnotherProgram(_ urls: [URL]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(
            urls.map { url -> NSPasteboardItem in
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                return item
            }
        )
    }

    /// A long list of files from another program is read in slices, and not at all once cancelled or stale (F039).
    @Test
    internal func aLongListOfFilesFromAnotherProgramIsReadInSlices() async throws {
        let urls = (0..<3_000).map { box.url("src/f\($0).txt") }
        writeAsAnotherProgram(urls)
        let items = try #require(pasteboard.pasteboardItems)
        // Read from a job's thread, the main thread does the reading a slice at a time.
        let reading = FileListReading(items, on: pasteboard)
        let flag = CancellationFlag()
        let outcome: FileListReading.Outcome = await withCheckedContinuation { done in
            Thread.detachNewThread {
                done.resume(
                    returning: reading.run(cancellation: flag) { _, _ in
                        // The progress is not checked here.
                    }
                )
            }
        }
        #expect(outcome == .read(urls))
        #expect(reading.slices >= 1)
        // Cancelled: nothing comes of it.
        let cancelled = FileListReading(items, on: pasteboard)
        flag.cancel()
        let abandoned: FileListReading.Outcome = await withCheckedContinuation { done in
            Thread.detachNewThread {
                done.resume(
                    returning: cancelled.run(cancellation: flag) { _, _ in
                        // The progress is not checked here.
                    }
                )
            }
        }
        #expect(abandoned == .abandoned)
        // The clipboard got other contents after the reading was set up: what was read is of
        // no use, and nothing is pasted from it.
        let stale = FileListReading(items, on: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("something else", forType: .string)
        let outdated = stale.run(cancellation: CancellationFlag()) { _, _ in
            // The progress is not checked here.
        }
        #expect(outdated == .abandoned)
    }

    /// A slice is short, and only file locations are taken from the clipboard's items.
    @Test
    internal func aSliceIsShortAndOnlyFileLocationsAreTaken() {
        // A slice may take a few thousandths of a second, so that the main thread gets its
        // turn between two of them.
        #expect(FileListReading.sliceTime <= 10_000_000)
        let item = NSPasteboardItem()
        item.setString("file:///tmp/a%20b.txt", forType: .fileURL)
        #expect(FileListReading.fileURL(of: item)?.path == "/tmp/a b.txt")
        let text = NSPasteboardItem()
        text.setString("https://example.invalid/x", forType: .fileURL)
        #expect(FileListReading.fileURL(of: text) == nil)
        let none = NSPasteboardItem()
        none.setString("just text", forType: .string)
        #expect(FileListReading.fileURL(of: none) == nil)
    }

    /// A long list from another program is read in a job and pasted whole; a short one is read without a job.
    @Test
    internal func aLongListFromAnotherProgramIsPastedWhole() throws {
        let count = ClipboardPlugin.readAtOnce + 44
        var urls: [URL] = []
        for index in 0..<count { urls.append(try box.file("src/f\(index).txt", "\(index)")) }
        writeAsAnotherProgram(urls)
        bench.right.focus()
        #expect(commands.isEnabled(.pasteFromClipboard))
        commands.perform(.pasteFromClipboard)
        #expect(bench.jobService.titles.contains("Reading the clipboard:"))
        #expect(namesOnDisk(box.url("t")).count == count && box.read("t/f\(count - 1).txt") == "\(count - 1)")
        // A short one is read as before, without a job of its own.
        try box.folder("u")
        bench.right.show(box.url("u"))
        writeAsAnotherProgram(Array(urls.prefix(3)))
        let before = bench.jobService.titles.filter { $0 == "Reading the clipboard:" }.count
        commands.perform(.pasteFromClipboard)
        #expect(namesOnDisk(box.url("u")) == ["f0.txt", "f1.txt", "f2.txt"])
        #expect(bench.jobService.titles.filter { $0 == "Reading the clipboard:" }.count == before)
    }

    /// A text that cannot be written leaves no draft behind (F040).
    @Test
    internal func aTextThatCannotBeWrittenLeavesNoDraftBehind() {
        struct DiskFull: LocalizedError {
            var errorDescription: String? { "The disk is full." }
        }
        pasteboard.clearContents()
        pasteboard.setString("some text", forType: .string)
        probe.writeFailure = DiskFull()
        #expect(commands.isEnabled(.pasteFromClipboard))
        commands.perform(.pasteFromClipboard)
        #expect(probe.base.allPaths == ["/A", "/A/one.txt"], "\(probe.base.allPaths)")
        #expect(bench.interaction.log.contains("inform: The clipboard cannot be pasted as a file!"))
        // And when it can be written, the file is there under its own name only.
        probe.writeFailure = nil
        commands.perform(.pasteFromClipboard)
        #expect(
            probe.base.allPaths == ["/A", "/A/Clipboard.txt", "/A/one.txt"]
                && probe.base.contents("/A/Clipboard.txt") == "some text"
        )
    }

    /// Whether there is something to paste is answered anew for every state of the clipboard.
    @Test
    internal func whetherThereIsSomethingToPasteIsAskedOncePerStateOfTheClipboard() {
        pasteboard.clearContents()
        pasteboard.setString("text", forType: .string)
        #expect(commands.isEnabled(.pasteFromClipboard) && commands.isEnabled(.pasteFromClipboard))
        // Another state of the clipboard is another answer, at once.
        pasteboard.clearContents()
        pasteboard.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("org.example.afm-test-unknown"))
        #expect(!commands.isEnabled(.pasteFromClipboard))
        pasteboard.clearContents()
        pasteboard.setString("again", forType: .string)
        #expect(commands.isEnabled(.pasteFromClipboard))
    }
}

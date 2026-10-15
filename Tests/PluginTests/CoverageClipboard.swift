import AFMContracts
import AFMKernel
import AppKit
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import ClipboardPlugin

/// The corners of the clipboard the other suites leave out: pasting without a transfer service,
/// contents that cannot be pasted, jobs that are cancelled or fail, and long lists from other
/// programs read while the main thread is busy.
@MainActor
@Suite(.serialized)
internal struct CoverageClipboard {
    /// The files: `/A` with one file, `/B` empty.
    private let memory = MemoryFileSystem()
    /// The memory files behind a layer that fails what a test names.
    private let files: CoverageSmallFiles
    /// The clipboard the plugin uses.
    private let scratch = ScratchPasteboard()

    /// The clipboard.
    private var pasteboard: NSPasteboard { scratch.pasteboard }

    /// The files of the panels.
    internal init() {
        memory.addFile("/A/one.txt", "1")
        memory.addDirectory("/B")
        files = CoverageSmallFiles(memory)
    }

    /// A kernel with the clipboard plugin only, its jobs run as `jobs` says.
    private func bench(_ jobs: CoverageSmallJobs.Mode) -> CoverageSmallBench {
        CoverageSmallBench(
            jobs,
            plugins: [ClipboardPlugin(pasteboard: pasteboard)],
            fileSystems: [LocalFileSystem(), files],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
    }

    /// The same, with jobs run at once.
    private func immediateBench() -> TestBench {
        TestBench(
            plugins: [ClipboardPlugin(pasteboard: pasteboard)],
            fileSystems: [LocalFileSystem(), files],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
    }

    /// What another program does: one pasteboard item per file, `count` of them.
    private func writeFilesAsAnotherProgram(_ count: Int) {
        pasteboard.clearContents()
        pasteboard.writeObjects(
            (0..<count)
                .map { index -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    item.setString(URL(fileURLWithPath: "/tmp/afm-\(index).txt").absoluteString, forType: .fileURL)
                    return item
                }
        )
    }

    /// Without a plugin that transfers files, files on the clipboard cannot be pasted.
    @Test
    internal func filesCannotBePastedWithoutATransferService() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "1")
        try box.folder("B")
        let bench = immediateBench()
        var rejected = 0
        bench.commands.onRejected = { rejected += 1 }
        bench.left.show(box.url("A"))
        bench.right.show(box.url("B"))
        bench.left.moveCursor(toName: "one.txt")
        bench.commands.perform(.copyToClipboard)
        bench.right.focus()
        bench.commands.perform(.pasteFromClipboard)
        #expect(rejected == 1 && !box.exists("B/one.txt"))
    }

    /// An empty text is on the clipboard but there is nothing to make a file of.
    @Test
    internal func anEmptyTextIsNotPasted() {
        let bench = immediateBench()
        pasteboard.clearContents()
        pasteboard.setString("", forType: .string)
        #expect(bench.commands.isEnabled(.pasteFromClipboard))
        bench.commands.perform(.pasteFromClipboard)
        #expect(bench.jobService.titles.isEmpty && memory.allPaths == ["/A", "/A/one.txt", "/B"])
    }

    /// A long list of items that are not files is pasted as the text it holds.
    @Test
    internal func aLongListOfOtherItemsIsPastedAsText() {
        let bench = immediateBench()
        pasteboard.clearContents()
        pasteboard.writeObjects(
            (0...ClipboardPlugin.readAtOnce)
                .map { index -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    item.setString("line \(index)", forType: .string)
                    return item
                }
        )
        bench.commands.perform(.pasteFromClipboard)
        #expect(bench.jobService.titles == ["Reading the clipboard:", "Paste:"])
        let lines = (0...ClipboardPlugin.readAtOnce).map { "line \($0)" }
        #expect(memory.contents("/A/Clipboard.txt") == lines.joined(separator: "\n"))
    }

    /// PNG data is written as it is; picture data that cannot be read is reported.
    @Test
    internal func pngIsKeptAndAPictureThatCannotBeReadIsReported() {
        let bench = immediateBench()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        bench.commands.perform(.pasteFromClipboard)
        let reader = try? memory.read(memory.url("/A/Clipboard.png"))
        #expect((try? reader?.read(upToCount: 64)) == png)
        pasteboard.clearContents()
        pasteboard.setData(Data([1, 2, 3]), forType: .png)
        bench.commands.perform(.pasteFromClipboard)
        #expect(bench.interaction.log.last == "inform: The clipboard cannot be pasted as a file!")
        #expect(!memory.exists("/A/Clipboard (2).png"))
    }

    /// A paste or a save of details whose job is cancelled before it starts writes nothing
    /// and says nothing.
    @Test
    internal func cancelledJobsWriteNothing() {
        let bench = bench(.cancelled)
        pasteboard.clearContents()
        pasteboard.setString("text", forType: .string)
        bench.commands.perform(.pasteFromClipboard)
        bench.left.moveCursor(toName: "one.txt")
        bench.commands.perform(ClipboardCommands.saveDetails, .text("details.txt"))
        #expect(bench.jobService.titles == ["Paste:", "Saving details:"])
        #expect(memory.allPaths == ["/A", "/A/one.txt", "/B"] && bench.interaction.log.isEmpty)
    }

    /// A write that fails is reported, and the half-written file is removed.
    @Test
    internal func aFailedWriteIsReportedAndLeavesNothing() {
        let bench = immediateBench()
        files.fails = [.write]
        pasteboard.clearContents()
        pasteboard.setString("text", forType: .string)
        bench.commands.perform(.pasteFromClipboard)
        #expect(bench.interaction.log == ["inform: The clipboard cannot be pasted as a file!"])
        bench.left.moveCursor(toName: "one.txt")
        bench.commands.perform(ClipboardCommands.saveDetails, .text("details.txt"))
        #expect(bench.interaction.log.last == "inform: The details cannot be saved!")
        #expect(memory.allPaths == ["/A", "/A/one.txt", "/B"])
        // A folder that is not there: the draft cannot even be made.
        files.fails = []
        bench.commands.perform(ClipboardCommands.saveDetails, .text("missing/details.txt"))
        #expect(bench.interaction.log.count == 3 && memory.allPaths == ["/A", "/A/one.txt", "/B"])
    }

    /// A write that fails because the job was cancelled meanwhile is no failure to report.
    @Test
    internal func aWriteEndedByCancellingIsNotReported() async {
        let bench = bench(.background)
        let jobs = bench.jobService
        files.fails = [.write]
        files.onFailure = { _ in jobs.cancelAll() }
        pasteboard.clearContents()
        pasteboard.setString("text", forType: .string)
        bench.commands.perform(.pasteFromClipboard)
        #expect(await jobs.settle { jobs.running == 0 })
        bench.left.moveCursor(toName: "one.txt")
        bench.commands.perform(ClipboardCommands.saveDetails, .text("details.txt"))
        #expect(await jobs.settle { jobs.running == 0 })
        #expect(jobs.titles == ["Paste:", "Saving details:"] && bench.interaction.log.isEmpty)
        #expect(memory.allPaths == ["/A", "/A/one.txt", "/B"])
    }

    /// A long list from another program is read while the main thread is busy: the job shows
    /// how far it is, Paste is not offered meanwhile, and the files read go to be pasted.
    @Test
    internal func aLongListReadInTheBackgroundShowsProgress() async {
        let bench = bench(.background)
        let jobs = bench.jobService
        var rejected = 0
        bench.commands.onRejected = { rejected += 1 }
        writeFilesAsAnotherProgram(ClipboardPlugin.readAtOnce + 1)
        bench.commands.perform(.pasteFromClipboard)
        bench.commands.perform(.pasteFromClipboard)
        // The main thread holds on until the job has had to report: the reading waits for it.
        #expect(Wait.until { jobs.reportCount.value > 0 })
        #expect(await jobs.settle { jobs.running == 0 })
        #expect(jobs.titles == ["Reading the clipboard:"])
        #expect(jobs.reports.first?.lines.last?.hasSuffix("of \(ClipboardPlugin.readAtOnce + 1) files") == true)
        // The second Paste was refused while the job ran; read whole, the files go to the
        // transfer service, and there is none here.
        #expect(rejected == 2)
    }

    /// A long list whose clipboard changes before it is read is given up.
    @Test
    internal func aLongListGivesWayToNewContents() async {
        let bench = bench(.background)
        let jobs = bench.jobService
        writeFilesAsAnotherProgram(ClipboardPlugin.readAtOnce + 1)
        bench.commands.perform(.pasteFromClipboard)
        pasteboard.clearContents()
        pasteboard.setString("new", forType: .string)
        #expect(await jobs.settle { jobs.running == 0 })
        #expect(jobs.titles == ["Reading the clipboard:"] && !memory.exists("/A/Clipboard.txt"))
    }

    /// A list whose clipboard changes while its last slice is read is given up as well.
    @Test
    internal func aListThatChangesWhileItsLastSliceIsReadIsGivenUp() throws {
        let provider = CoverageClipboardChanger(pasteboard)
        let late = NSPasteboardItem()
        late.setDataProvider(provider, forTypes: [.fileURL])
        let first = NSPasteboardItem()
        first.setString(URL(fileURLWithPath: "/tmp/a.txt").absoluteString, forType: .fileURL)
        pasteboard.clearContents()
        pasteboard.writeObjects([first, late])
        let items = try #require(pasteboard.pasteboardItems)
        let reading = FileListReading(items, on: pasteboard)
        let outcome = reading.run(cancellation: CancellationFlag()) { _, _ in
            // Read on the main thread at once: there is no progress to show.
        }
        #expect(outcome == .abandoned)
        #expect(provider.asked)
    }

    /// A reference to a file by its number is turned into the file's path.
    @Test
    internal func aFileReferenceBecomesAPath() throws {
        let box = try Sandbox()
        try box.file("ref.txt", "x")
        // Made by Core Foundation: Foundation's `URL` gives the path instead of the number.
        let reference = try #require(CFURLCreateFileReferenceURL(nil, box.url("ref.txt") as CFURL, nil))
        let text = CFURLGetString(reference.takeRetainedValue()) as String
        #expect(text.hasPrefix("file:///.file/"))
        let item = NSPasteboardItem()
        item.setString(text, forType: .fileURL)
        let path = FileListReading.fileURL(of: item)?.resolvingSymlinksInPath().path
        #expect(path == box.url("ref.txt").resolvingSymlinksInPath().path)
    }
}

import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing
import VirtualFoldersPlugin

@testable import MacIntegrationPlugin

/// The Mac-integration commands beyond the other suites, with nothing started and no system
/// panel shown: locations that are not local, choices given up, jobs cancelled, tags that
/// cannot be set, and log lines of any text.
@MainActor
@Suite
internal struct CoverageMacIntegration {
    /// The local files: `A` with two text files.
    private let box: Sandbox
    /// Files in memory, which no application can open.
    private let memory = MemoryFileSystem()
    /// The clipboard the plugin writes to.
    private let scratch = ScratchPasteboard()

    /// The files.
    internal init() throws {
        box = try Sandbox()
        try box.file("A/notes.txt", "hello")
        try box.file("A/other.txt", "world")
        try box.folder("B")
        memory.addFile("/M/remote.txt", "far")
    }

    /// A kernel with the plugin, which starts nothing; with `applications` nil it asks Launch
    /// Services which applications open a file (a question, which opens nothing).
    private func bench(
        _ jobs: CoverageSmallJobs.Mode = .cancelledFrom(first: 99),
        applications: (@Sendable (URL) -> [URL])? = { _ in [] }
    ) -> (CoverageSmallBench, MacIntegrationPlugin) {
        let mac = MacIntegrationPlugin(
            launchesApplications: false,
            pasteboard: scratch.pasteboard,
            applications: applications
        )
        let bench = CoverageSmallBench(
            jobs,
            plugins: [VirtualFoldersPlugin(), mac],
            fileSystems: [LocalFileSystem(), memory],
            left: box.url("A"),
            right: box.url("B")
        )
        return (bench, mac)
    }

    /// Log lines show one line of any text: breaks, tabs and invisible characters are written
    /// out, joiners are kept, and a long text is cut.
    @Test
    internal func logLinesOfAnyText() {
        #expect(DisplayText.oneLine("a\rb\tc\u{1}d\u{200D}e") == "a\\rb\\tc\\u{1}d\u{200D}e")
        #expect(DisplayText.oneLine("abcdef", limit: 3) == "abc…")
    }

    /// Edit takes local files only; Choose Editor without a choice keeps the editor.
    @Test
    internal func editAndChooseEditorWithoutAnythingToDo() {
        let (bench, mac) = bench()
        bench.left.moveCursor(toName: "notes.txt")
        bench.commands.perform(.edit, .location(memory.url("/M/remote.txt")))
        bench.commands.perform(MacIntegrationPlugin.chooseEditor)
        #expect(mac.log.isEmpty && bench.kernel.settings.data(forKey: MacIntegrationPlugin.editorKey) == nil)
    }

    /// Open With: a cancelled search for applications asks nothing; Other… without a choice
    /// opens nothing; the applications Launch Services knows are offered, the default first.
    @Test
    internal func openWithGivenUp() {
        let (cancelled, _) = bench(.cancelled)
        cancelled.left.moveCursor(toName: "notes.txt")
        cancelled.commands.perform(MacIntegrationPlugin.openWith)
        #expect(cancelled.interaction.forms.isEmpty && cancelled.jobService.titles == ["Applications:"])
        let (asking, mac) = bench(applications: nil)
        asking.left.moveCursor(toName: "notes.txt")
        asking.interaction.formAnswers = [.values(["row": .index(99)])]
        asking.commands.perform(MacIntegrationPlugin.openWith)
        guard case .list(let rows, _)? = asking.interaction.forms.first?.first?.kind else {
            Issue.record("no list of applications")
            return
        }
        #expect(rows.last == "Other…" && rows.first?.hasSuffix(" (default)") == true)
        #expect(mac.opened.isEmpty)
    }

    /// Reveal with nothing marked and the cursor on `[..]` shows the folder itself.
    @Test
    internal func revealTheFolderItself() {
        let (bench, mac) = bench()
        bench.left.model.moveCursor(to: 0)
        bench.commands.perform(.revealInFinder)
        #expect(mac.log == ["reveal " + box.url("A").path])
    }

    /// Finder tags: marked items that are not local give nothing to tag; tags of a file that has
    /// gone cannot be set, which is said.
    @Test
    internal func tagsOfNothingAndOfFilesThatHaveGone() throws {
        let (bench, mac) = bench()
        let virtual = try #require(bench.kernel.fileSystems.all.compactMap { $0 as? VirtualFileSystem }.first)
        let list = virtual.register(
            files: [box.url("A/notes.txt"), memory.url("/M/remote.txt")],
            title: "Mixed",
            origin: nil
        )
        bench.left.show(list)
        bench.left.model.setSelected(true, names: [memory.displayPath(memory.url("/M/remote.txt"))])
        bench.left.model.moveCursor(to: bench.left.model.row(ofName: box.url("A/notes.txt").path) ?? 0)
        bench.commands.perform(MacIntegrationPlugin.editTags)
        #expect(bench.jobService.titles.isEmpty)
        bench.left.show(box.url("A"))
        bench.left.moveCursor(toName: "other.txt")
        try FileManager.default.removeItem(at: box.url("A/other.txt"))
        bench.interaction.promptAnswers = [.text("Red")]
        bench.commands.perform(MacIntegrationPlugin.editTags)
        #expect(bench.interaction.log.last == "inform: The tags could not be set")
        #expect(mac.log.last == "tags " + box.url("A/other.txt").path + ": Red")
    }

    /// A drive that is released while nothing is previewed closes nothing.
    @Test
    internal func releasingADriveWithoutAPreview() {
        let (bench, mac) = bench()
        bench.kernel.fileSystems.releaseVolume(box.url("A"))
        #expect(mac.log.isEmpty)
    }
}

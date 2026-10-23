import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import SelectionPlugin
import TestSupport
import Testing

@testable import FilePropertiesPlugin

/// Second pass of review round 2 for the commands of the file properties: what the panel shows when a job's
/// dialog comes (F037), owner and group names (F038), folder sizes (F070) and what a command changed (F010).
@MainActor
@Suite
internal struct Review2FileopsP2PropertyCommandTests {
    /// The temporary folder: `d` with two files and a folder, `other`, and `files` with one file.
    internal let box: Sandbox
    /// Notes every dialog and answers it as scripted.
    internal let interaction = ScriptedInteraction()
    /// Does a job's work at once and keeps its completion until the test delivers it.
    internal let jobs = P2DeferredJobs()
    /// A kernel with the file properties and the selection, its left panel on `d` and its right one on `other`.
    internal let bench: P2Bench

    /// The files and the kernel.
    internal init() throws {
        box = try Sandbox()
        try box.file("d/a.txt", "a")
        try box.file("d/b.txt", "b")
        try box.folder("d/folder")
        try box.file("d/folder/inside.txt", "12345")
        try box.folder("other")
        try box.file("files/only.txt", "x")
        bench = P2Bench(
            plugins: [FilePropertiesPlugin(launchesApplications: false), SelectionPlugin()],
            fileSystems: [LocalFileSystem()],
            left: box.url("d"),
            right: box.url("other"),
            interaction: interaction,
            jobs: jobs,
            settings: MemorySettings()
        )
    }

    /// A dialog about what the panel showed when the command was given is not shown once the panel shows another
    /// folder (F037).
    @Test
    internal func aDialogIsNotShownOnceThePanelShowsAnotherFolder() throws {
        bench.left.moveCursor(toName: "a.txt")
        for command in [CommandID.setAttributes, .editComment] {
            #expect(bench.commands.perform(command))
            // The job has read what the dialog needs; the user has gone elsewhere meanwhile.
            bench.left.show(box.url("other"))
            jobs.deliver()
            #expect(!interaction.log.contains { $0.hasPrefix("form") }, "\(command)")
            bench.left.show(box.url("d"))
            bench.left.moveCursor(toName: "a.txt")
        }
        try FileManager.default.createSymbolicLink(
            at: box.url("d/link"),
            withDestinationURL: box.url("files/only.txt")
        )
        bench.left.reload()
        bench.left.moveCursor(toName: "link")
        #expect(bench.commands.perform(.showLinkTarget))
        bench.left.show(box.url("other"))
        jobs.deliver()
        // The panel stays where the user took it.
        #expect(bench.left.model.directory.isSameLocation(as: box.url("other")))
        // In the folder the command was given in, the dialog comes and the link is followed.
        bench.left.show(box.url("d"))
        bench.left.moveCursor(toName: "a.txt")
        #expect(bench.commands.perform(.setAttributes))
        jobs.deliver()
        #expect(interaction.log.contains("form: Change attributes: a.txt"))
        bench.left.moveCursor(toName: "link")
        #expect(bench.commands.perform(.showLinkTarget))
        jobs.deliver()
        #expect(bench.left.model.directory.isSameLocation(as: box.url("files")))
    }

    /// The names of owner and group are looked up in the job, before the dialog, not while it is made (F038).
    @Test
    internal func ownerAndGroupAreLookedUpBeforeTheDialogNotWhileItIsMade() throws {
        bench.left.moveCursor(toName: "a.txt")
        var afterWork = -1
        jobs.afterWork = { afterWork = LocalInfo.nameLookups }
        #expect(bench.commands.perform(.setAttributes))
        let details = try #require(LocalInfo.details(box.url("d/a.txt")))
        #expect(afterWork >= 0)
        // The dialog shows both names…
        jobs.deliver()
        let fields = try #require(interaction.forms.last)
        #expect(fields.contains { $0.label.contains("now \(LocalInfo.userName(details.ownerID))") })
        // …and found them known: nothing was asked of the system after the job's work.
        #expect(LocalInfo.nameLookups == afterWork)
    }

    /// All folder sizes are offered only where there are folders, and belong to the list they were worked out
    /// for (F070).
    @Test
    internal func allFolderSizesAreOfferedOnlyWhereThereAreFolders() {
        #expect(bench.commands.isEnabled(.countDirectoryContents))
        bench.left.show(box.url("files"))
        #expect(!bench.commands.isEnabled(.countDirectoryContents))
        bench.left.show(box.url("d"))
        #expect(bench.commands.perform(.countDirectoryContents))
        jobs.deliver()
        #expect(bench.left.model.items.first { $0.name == "folder" }?.computedSize == 5)
        // The sizes belong to the list they were worked out for.
        #expect(bench.commands.perform(.countDirectoryContents))
        bench.left.show(box.url("other"))
        jobs.deliver()
        #expect(bench.left.model.items.allSatisfy { $0.computedSize == nil })
    }

    /// The sizes are shown also when the list of the same folder changed while they were worked out.
    @Test
    internal func theSizesAreShownAlsoWhenTheListChangedWhileTheyWereWorkedOut() throws {
        #expect(bench.commands.perform(.countDirectoryContents))
        // The same folder, another list: a file was added while the job ran.
        try box.file("d/zz-new.txt", "new")
        bench.left.reload()
        jobs.deliver()
        #expect(bench.left.model.items.first { $0.name == "folder" }?.computedSize == 5)
    }

    /// What a command changed is shown in the panel afterwards, and Calculate Occupied Space keeps the sizes and
    /// marks (F010).
    @Test
    internal func whatACommandChangedIsShownInThePanelAfterwards() {
        bench.left.moveCursor(toName: "a.txt")
        #expect(bench.commands.perform(.setAttributes, .text("= +m600")))
        jobs.deliver()
        #expect(bench.left.model.items.first { $0.name == "a.txt" }?.permissions == 0o600)
        bench.left.model.setSelection(names: ["folder", "b.txt"])
        #expect(bench.commands.perform(.occupiedSpace))
        jobs.deliver()
        #expect(interaction.log.contains("inform: Total space occupied:"))
        #expect(bench.left.model.items.first { $0.name == "folder" }?.computedSize == 5)
        #expect(bench.left.model.selectionCount == 2)
    }
}

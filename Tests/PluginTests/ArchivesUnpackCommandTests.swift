import AFMContracts
import AFMKernel
import FileOperationsPlugin
import Foundation
import LocalFileSystemPlugin
import MacIntegrationPlugin
import NavigationPlugin
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The unpack and test commands, and archives on another file system.
@MainActor
@Suite
internal struct ArchivesUnpackCommandTests {
    /// The panels, the plugins and the sandbox.
    private let fixture: ArchivePanelsFixture

    /// The sandbox that holds `A` and `B`.
    private var box: Sandbox { fixture.box }
    /// The file system in memory.
    private var memory: MemoryFileSystem { fixture.memory }
    /// The plugin under test.
    private var archives: ArchivesPlugin { fixture.archives }
    /// The kernel with the plugins and the two panels.
    private var bench: TestBench { fixture.bench }
    /// The commands of the kernel.
    private var commands: CommandRegistry { fixture.commands }
    /// The left panel, on `A` at the start.
    private var left: FakePanel { fixture.left }
    /// The right panel, on `B` at the start.
    private var right: FakePanel { fixture.right }
    /// The scripted answers of the user, and what was asked.
    private var interaction: ScriptedInteraction { fixture.interaction }

    /// A fresh fixture for each test.
    internal init() throws {
        fixture = try ArchivePanelsFixture()
    }

    /// Unpack writes into the target panel's folder, asks about existing files, and takes a mask and several archives.
    @Test
    internal func unpackArchivesIntoTheTargetPanel() throws {
        left.moveCursor(toName: "tree.zip")
        interaction.formAnswers = [.accept]
        commands.perform(.unpackFiles)
        let fields = try #require(interaction.forms.last)
        #expect(fields.map(\.key) == ["target", "mask", "paths", "separate", "overwrite"])
        #expect(
            fields.first?.initialValue == .text(box.url("B").path)
                && fields.first?.label == "Unpack specific files from archive to:"
        )
        #expect(snapshot(box.url("B/tree")) == snapshot(box.url("A/tree")) && right.names == ["tree"])
        #expect(bench.jobService.reports.last?.bytesDone == 317_605)

        // Again: every existing file is asked about; "Skip all" leaves them.
        try box.file("B/tree/readme.txt", "changed here")
        interaction.formAnswers = [.accept]
        interaction.choiceAnswers = [3]
        commands.perform(.unpackFiles)
        #expect(
            interaction.log.filter { $0.hasPrefix("choose: Overwrite:") }.count == 1
                && box.read("B/tree/readme.txt") == "changed here"
        )
        interaction.formAnswers = [.values(["overwrite": .flag(true)])]
        commands.perform(.unpackFiles)
        #expect(box.read("B/tree/readme.txt")?.count == 17_600)

        try unpackSeveralWithAMask()
    }

    /// Inside an archive, unpack takes the marked entries, or everything below the folder shown that fits the mask.
    @Test
    internal func unpackFromInsideAnArchive() {
        enter("tree.zip")
        enter("tree")
        // The marked entries, folders with everything in them, relative to the folder shown.
        left.model.select(mask: "sub hollow")
        interaction.formAnswers = [.accept]
        commands.perform(.unpackFiles)
        #expect(interaction.forms.last?.first?.label == "Unpack 2 file(s) to")
        #expect(
            namesOnDisk(box.url("B")) == ["hollow", "sub"]
                && namesOnDisk(box.url("B/sub")) == ["data.bin", "inner.txt"]
        )
        // Nothing marked: everything below the folder shown that fits the mask.
        left.model.clearSelection()
        interaction.formAnswers = [.values(["mask": .text("*.txt"), "target": .text(box.url("B/texts").path)])]
        commands.perform(.unpackFiles)
        #expect(
            namesOnDisk(box.url("B/texts")) == ["readme.txt", "sub"]
                && namesOnDisk(box.url("B/texts/sub")) == ["inner.txt"]
        )
    }

    /// Test archives reports sound archives and damaged ones; inside an archive it tests that archive.
    @Test
    internal func testArchivesReportsWhatIsDamaged() throws {
        #expect(runTool("/usr/bin/zip", ["-qr0", "stored.zip", "tree"], in: box.url("A")).status == 0)
        #expect(runTool("/usr/bin/tar", ["-czf", "tree.tgz", "tree"], in: box.url("A")).status == 0)
        left.reload()
        left.model.select(mask: "*.zip *.tgz")
        commands.perform("cm_TestArchive")
        #expect(interaction.log.last == "inform: Archive test" && bench.jobService.titles == ["Testing:"])

        var bytes = try Data(contentsOf: box.url("A/stored.zip"))
        let position = try #require(bytes.range(of: Data("0123456789012345".utf8))).lowerBound + 5_000
        bytes[position] = 0x58
        try bytes.write(to: box.url("A/stored.zip"))
        commands.perform("cm_TestArchive")
        #expect(interaction.log.last == "inform: Errors found in archive!")
        // Inside an archive the archive itself is tested.
        left.model.clearSelection()
        enter("tree.zip")
        commands.perform("cm_TestArchive")
        #expect(interaction.log.last == "inform: Archive test")
    }

    // MARK: Other file systems

    /// An archive on another file system opens, is copied from and changed, and is packed onto, as on the disk.
    @Test
    internal func archivesOnAnotherFileSystemOpenTheSameWay() throws {
        let bytes = try Data(contentsOf: box.url("A/tree.zip"))
        let writer = try memory.write(memory.addDirectory("/store").appending(name: "tree.zip"))
        try writer.write(bytes)
        try writer.close(attributes: FileAttributes())
        left.show(memory.url("/store"))
        enter("tree.zip")
        #expect(left.failures.isEmpty && left.model.directory.scheme == "zip" && left.names == ["tree"])
        enter("tree")
        #expect(bench.kernel.fileSystems.displayPath(left.model.directory) == "mem:/store/tree.zip/tree")
        // Copy out to the disk, by the dialog.
        left.moveCursor(toName: "readme.txt")
        interaction.promptAnswers = [.text(box.url("B").path + "/")]
        commands.perform(.copy)
        // A plain path typed inside an archive is a place on the disk, wherever the archive is.
        #expect(box.exists("B/readme.txt") && !memory.exists(box.url("B").path + "/readme.txt"))
        // New folder inside, written back to where the archive lives.
        interaction.promptAnswers = [.text("made")]
        commands.perform(.makeDirectory)
        #expect(left.names.contains("made") && archives.flushPendingChanges().isEmpty)
        commands.perform(.goToParent)
        commands.perform(.goToParent)
        #expect(
            left.model.directory.isSameLocation(as: memory.url("/store")) && left.model.cursorItem?.name == "tree.zip"
        )
        #expect(left.model.cursorItem?.size != Int64(bytes.count))
        // Pack onto that file system.
        left.show(box.url("A"))
        right.show(memory.url("/store"))
        left.focus()
        left.moveCursor(toName: "notes.txt")
        interaction.formAnswers = [.accept]
        commands.perform(.packFiles)
        #expect(
            interaction.forms.last?.first?.initialValue == .text("mem:/store/notes.zip")
                && right.names == ["notes.zip", "tree.zip"]
        )
    }

    /// Enter on an item of the left panel.
    private func enter(_ name: String) {
        fixture.enter(name)
    }

    /// Unpacks a ZIP and a TAR by a mask into a folder each, reports a file that is no archive, and unpacks next
    /// to the archive when the target is empty.
    private func unpackSeveralWithAMask() throws {
        // A mask, without paths, into a folder per archive; several archives at once.
        #expect(
            runTool("/usr/bin/tar", ["-cjf", "second.tar.bz2", "notes.txt", "todo.txt"], in: box.url("A")).status == 0
        )
        left.reload()
        left.model.select(mask: "*.zip *.bz2")
        interaction.formAnswers = [
            .values([
                "mask": .text("*.txt"), "paths": .flag(false), "separate": .flag(true),
                "target": .text(box.url("B/out").path)
            ])
        ]
        commands.perform(.unpackFiles)
        #expect(namesOnDisk(box.url("B/out")) == ["second", "tree"])
        #expect(
            namesOnDisk(box.url("B/out/tree")) == ["inner.txt", "readme.txt"]
                && namesOnDisk(box.url("B/out/second")) == ["notes.txt", "todo.txt"]
        )
        #expect(left.model.selection.isEmpty)

        // Something that is no archive is reported; the rest is unpacked.
        left.model.select(mask: "notes.txt *.bz2")
        interaction.formAnswers = [.values(["target": .text(box.url("B/mixed").path)])]
        commands.perform(.unpackFiles)
        #expect(
            interaction.log.last == "inform: Some files could not be unpacked!"
                && namesOnDisk(box.url("B/mixed")) == ["notes.txt", "todo.txt"]
        )
        // An empty target is the archive's own folder.
        left.model.clearSelection()
        left.moveCursor(toName: "second.tar.bz2")
        try FileManager.default.removeItem(at: box.url("A/notes.txt"))
        interaction.formAnswers = [.values(["target": .text(""), "overwrite": .flag(true)])]
        commands.perform(.unpackFiles)
        #expect(box.read("A/notes.txt") == "notes")
    }
}

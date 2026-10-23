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

/// File operations of panels on a ZIP: copy out and in with F5, new folder, rename, move and delete inside.
@MainActor
@Suite
internal struct ArchivesPanelOperationsTests {
    /// The panels, the plugins and the sandbox.
    private let fixture: ArchivePanelsFixture

    /// The sandbox that holds `A` and `B`.
    private var box: Sandbox { fixture.box }
    /// The plugin under test.
    private var archives: ArchivesPlugin { fixture.archives }
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

    /// F5 copies a file and a folder out of a ZIP into the target panel's folder.
    @Test
    internal func copyOutOfAnArchiveWithTheCopyCommand() {
        enter("tree.zip")
        enter("tree")
        // One file to the target panel's folder, as the dialog proposes it.
        left.moveCursor(toName: "readme.txt")
        interaction.promptAnswers = [.accept]
        commands.perform(.copy)
        #expect(interaction.log.last == "prompt: Copy \"readme.txt\" to [\(box.url("B").path)/readme.txt]")
        #expect(box.read("B/readme.txt")?.count == 17_600)
        // A folder with everything in it.
        left.moveCursor(toName: "sub")
        interaction.promptAnswers = [.accept]
        commands.perform(.copy)
        #expect(box.read("B/sub/inner.txt") == "inner" && box.read("B/sub/data.bin")?.count == 300_000)
        #expect(namesOnDisk(box.url("B")) == ["readme.txt", "sub"])
        right.reload()
        #expect(right.names == ["sub", "readme.txt"])
        #expect(archives.flushPendingChanges().isEmpty && isSound("A/tree.zip"))
    }

    /// F5 copies files and a folder into a ZIP, which holds them as soon as the job has put them in place.
    @Test
    internal func copyIntoAnArchiveWithTheCopyCommand() {
        enter("tree.zip", in: left)
        enter("tree", in: left)
        enter("sub", in: left)
        right.show(box.url("A"))
        right.focus()
        right.model.select(mask: "*.txt")
        interaction.promptAnswers = [.accept]
        commands.perform(.copy)
        // The target is written the way the archive panel shows its path.
        #expect(interaction.log.last == "prompt: Copy 2 file(s) to [\(box.url("A/tree.zip").path)/tree/sub/*.*]")
        // The panel inside the archive shows the new files at once…
        #expect(left.names == ["data.bin", "inner.txt", "notes.txt", "todo.txt"])
        // …and the archive file holds them as soon as the job has put them under their names:
        // nothing is left waiting that a failed write could lose.
        let held = unzipList("A/tree.zip")
        #expect(Set(held.suffix(2)) == ["tree/sub/notes.txt", "tree/sub/todo.txt"], "\(held)")
        #expect(archives.flushPendingChanges().isEmpty && isSound("A/tree.zip"))
        #expect(unzipList("A/tree.zip") == held)
        #expect(
            runTool("/usr/bin/unzip", ["-p", box.url("A/tree.zip").path, "tree/sub/todo.txt"], in: nil).output == "todo"
        )
        #expect(namesOnDisk(box.url("A")) == ["notes.txt", "todo.txt", "tree", "tree.zip"])

        // A whole folder, and a name collision answered with Skip.
        right.model.clearSelection()
        right.moveCursor(toName: "tree")
        interaction.promptAnswers = [.accept]
        commands.perform(.copy)
        right.moveCursor(toName: "notes.txt")
        interaction.promptAnswers = [.accept]
        interaction.choiceAnswers = [2]
        commands.perform(.copy)
        #expect(interaction.log.contains { $0.hasPrefix("choose: Overwrite:") })
        #expect(archives.flushPendingChanges().isEmpty && isSound("A/tree.zip"))
        #expect(unzipList("A/tree.zip").contains("tree/sub/tree/sub/data.bin"))
    }

    /// New folder, rename, move and delete work inside a ZIP, and one write (or quitting) brings them to the file.
    @Test
    internal func newFolderRenameAndDeleteInsideAnArchive() {
        enter("tree.zip")
        enter("tree")
        interaction.promptAnswers = [.text("made/deeper")]
        commands.perform(.makeDirectory)
        #expect(left.names == ["hollow", "made", "sub", "readme.txt"] && left.model.cursorItem?.name == "made")

        left.moveCursor(toName: "readme.txt")
        commands.perform(.renameOnly, .text("LIESMICH.txt"))
        #expect(
            left.names == ["hollow", "made", "sub", "LIESMICH.txt"] && left.model.cursorItem?.name == "LIESMICH.txt"
        )
        // F6 with a new name renames; into a folder of the same archive it moves.
        left.moveCursor(toName: "sub")
        interaction.promptAnswers = [.text("unter")]
        commands.perform(.renameMove)
        left.moveCursor(toName: "LIESMICH.txt")
        interaction.promptAnswers = [.text(box.url("A/tree.zip").path + "/tree/unter/")]
        commands.perform(.renameMove)
        #expect(left.names == ["hollow", "made", "unter"])

        // Delete: there is no Trash in an archive, so the question is the direct one; a
        // folder with contents is asked about once more.
        left.moveCursor(toName: "hollow")
        interaction.choiceAnswers = [0]
        commands.perform(.delete)
        #expect(interaction.log.contains { $0.hasPrefix("choose: Permanently delete") })
        left.moveCursor(toName: "made")
        interaction.choiceAnswers = [0, 0]
        commands.perform(.delete)
        #expect(left.names == ["unter"])
        // Nothing of this has touched the archive file yet; one write brings it all.
        #expect(unzipList("A/tree.zip").contains("tree/readme.txt"))
        #expect(archives.flushPendingChanges().isEmpty && isSound("A/tree.zip"))
        #expect(
            unzipList("A/tree.zip") == [
                "tree/", "tree/unter/", "tree/unter/LIESMICH.txt", "tree/unter/data.bin", "tree/unter/inner.txt"
            ]
        )
        // Quitting writes what is still waiting.
        interaction.promptAnswers = [.text("last")]
        commands.perform(.makeDirectory)
        archives.stop()
        #expect(unzipList("A/tree.zip").contains("tree/last/"))
    }

    /// Enter on an item of the left panel.
    private func enter(_ name: String) {
        fixture.enter(name)
    }

    /// Enter on an item of `panel`.
    private func enter(_ name: String, in panel: FakePanel) {
        fixture.enter(name, in: panel)
    }

    /// The member names of the ZIP at `path`, as the system's unzip lists them, sorted.
    private func unzipList(_ path: String) -> [String] {
        fixture.unzipList(path)
    }

    /// Whether the system's unzip finds the ZIP at `path` sound.
    private func isSound(_ path: String) -> Bool {
        fixture.isSound(path)
    }
}

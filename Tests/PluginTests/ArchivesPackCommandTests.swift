import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The pack command: where and how it packs, its options, encryption and adding to an archive.
@MainActor
@Suite
internal struct ArchivesPackCommandTests {
    /// The panels, the plugins and the sandbox.
    private let fixture: ArchivePanelsFixture

    /// The sandbox that holds `A` and `B`.
    private var box: Sandbox { fixture.box }
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

    /// Pack proposes an archive in the target panel named after what is packed, in the format and place asked for.
    @Test
    internal func packIntoTheTargetPanel() throws {
        left.moveCursor(toName: "tree")
        interaction.formAnswers = [.accept]
        commands.perform(.packFiles)
        let fields = try #require(interaction.forms.last)
        // The proposal: named after the operand, in the target panel's folder (spec 08 › Pack dialog).
        #expect(
            fields.first?.label == "Pack 1 file(s) to the archive"
                && fields.first?.initialValue == .text(box.url("B/tree.zip").path)
        )
        #expect(
            fields.map(\.key) == [
                "archive", "format", "level", "paths", "recurse", "move", "separate", "skipBase", "tarFirst", "encrypt"
            ]
        )
        #expect(bench.jobService.titles == ["Packing:"] && interaction.log.last == "form: Pack files")
        // No message; the archive appears in the target panel with the cursor on it.
        #expect(right.names == ["tree.zip"] && isSound("B/tree.zip"))
        #expect(
            unzipList("B/tree.zip") == [
                "tree/", "tree/hollow/", "tree/readme.txt", "tree/sub/", "tree/sub/data.bin", "tree/sub/inner.txt"
            ]
        )
        #expect(bench.jobService.reports.last?.itemsDone == 6 && bench.jobService.reports.last?.bytesDone == 317_605)
        #expect(box.exists("A/tree"))

        // Several items: named after the source folder. Another packer rewrites the ending.
        left.model.select(mask: "*.txt")
        interaction.formAnswers = [.values(["format": .index(2), "level": .index(9)])]
        commands.perform(.packFiles)
        #expect(interaction.forms.last?.first?.initialValue == .text(box.url("B/A.zip").path))
        #expect(right.names == ["A.tar.gz", "tree.zip"] && left.model.selection.isEmpty)
        #expect(
            runTool("/usr/bin/tar", ["-tzf", box.url("B/A.tar.gz").path], in: nil).output == "notes.txt\ntodo.txt\n"
        )

        // A prefix names the packer too, and the name may be any.
        left.moveCursor(toName: "notes.txt")
        interaction.formAnswers = [.values(["archive": .text("tar:" + box.url("B/deep/plain").path)])]
        commands.perform(.packFiles)
        #expect(runTool("/usr/bin/tar", ["-tf", box.url("B/deep/plain.tar").path], in: nil).output == "notes.txt\n")
        // An existing archive that is not a ZIP is replaced only after a question.
        interaction.formAnswers = [.values(["archive": .text("tar:" + box.url("B/deep/plain").path)])]
        interaction.choiceAnswers = [1]
        left.moveCursor(toName: "todo.txt")
        commands.perform(.packFiles)
        #expect(interaction.log.contains { $0.hasPrefix("choose: Overwrite:") })
        #expect(runTool("/usr/bin/tar", ["-tf", box.url("B/deep/plain.tar").path], in: nil).output == "notes.txt\n")
    }

    /// The pack options: no paths, no recursion, separate archives, a TAR first, and moving into the archive.
    @Test
    internal func packOptions() {
        // Without path names everything is stored flat; without recursion only the files directly inside.
        left.moveCursor(toName: "tree")
        interaction.formAnswers = [.values(["paths": .flag(false), "archive": .text(box.url("B/flat.zip").path)])]
        commands.perform(.packFiles)
        #expect(unzipList("B/flat.zip") == ["data.bin", "inner.txt", "readme.txt"])
        interaction.formAnswers = [.values(["recurse": .flag(false), "archive": .text(box.url("B/shallow.zip").path)])]
        commands.perform(.packFiles)
        #expect(unzipList("B/shallow.zip") == ["tree/", "tree/readme.txt"])

        // Separate archives; a single-file packer makes one per file by itself.
        left.model.select(mask: "*.txt")
        interaction.formAnswers = [.values(["format": .index(5)])]
        commands.perform(.packFiles)
        #expect(namesOnDisk(box.url("B")) == ["flat.zip", "notes.txt.gz", "shallow.zip", "todo.txt.gz"])
        #expect(runTool("/usr/bin/gzip", ["-dc", box.url("B/todo.txt.gz").path], in: nil).output == "todo")
        left.model.clearSelection()
        left.moveCursor(toName: "tree")
        interaction.formAnswers = [
            .values(["separate": .flag(true), "skipBase": .flag(true), "archive": .text(box.url("B/sep/").path + "/")])
        ]
        commands.perform(.packFiles)
        #expect(unzipList("B/sep/tree.zip") == ["hollow/", "readme.txt", "sub/", "sub/data.bin", "sub/inner.txt"])
        // A folder into a single-file format: only through a TAR.
        interaction.formAnswers = [.values(["format": .index(7), "archive": .text(box.url("B/x").path)])]
        commands.perform(.packFiles)
        #expect(interaction.log.last == "inform: Packing failed!" && !box.exists("B/x.xz"))
        interaction.formAnswers = [
            .values(["format": .index(7), "tarFirst": .flag(true), "archive": .text(box.url("B/x").path)])
        ]
        commands.perform(.packFiles)
        #expect(
            runTool("/usr/bin/tar", ["-tJf", box.url("B/x.tar.xz").path], in: nil).output.split(separator: "\n").count
                == 6
        )

        // Move to archive deletes what was packed, after the archive is complete and tested.
        left.model.select(mask: "*.txt")
        interaction.formAnswers = [.values(["archive": .text(box.url("B/moved.zip").path)])]
        commands.perform("cm_MoveToArchive")
        #expect(interaction.forms.last?.first { $0.key == "move" }?.initialValue == .flag(true))
        #expect(unzipList("B/moved.zip") == ["notes.txt", "todo.txt"] && left.names == ["tree", "tree.zip"])
        left.moveCursor(toName: "tree")
        interaction.formAnswers = [.values(["move": .flag(true), "archive": .text(box.url("B/gone.zip").path)])]
        commands.perform(.packFiles)
        #expect(!box.exists("A/tree") && isSound("B/gone.zip") && unzipList("B/gone.zip").count == 6)
    }

    /// Pack encrypts with a password asked twice, adds to an existing ZIP, and packs into a ZIP open in the panel.
    @Test
    internal func packEncryptedAndIntoAnExistingArchive() throws {
        left.moveCursor(toName: "notes.txt")
        // The password is asked for twice; a mismatch asks again.
        interaction.formAnswers = [
            .values(["encrypt": .flag(true)]), .values(["password": .text("one"), "repeat": .text("two")]),
            .values(["password": .text("sesame"), "repeat": .text("sesame"), "legacy": .flag(true)])
        ]
        commands.perform(.packFiles)
        #expect(interaction.log.suffix(3) == ["form: Pack files", "form: Encrypt", "form: Encrypt"])
        #expect(
            runTool("/usr/bin/unzip", ["-p", "-P", "sesame", box.url("B/notes.zip").path], in: nil).output == "notes"
        )
        #expect(runTool("/usr/bin/unzip", ["-tq", "-P", "wrong", box.url("B/notes.zip").path], in: nil).status != 0)
        // Only ZIP can.
        interaction.formAnswers = [.values(["encrypt": .flag(true), "format": .index(1)])]
        commands.perform(.packFiles)
        #expect(interaction.log.last == "inform: Only ZIP archives can be encrypted." && !box.exists("B/notes.tar"))

        // The same target again adds to the archive; a member packed again is replaced.
        try box.file("A/notes.txt", "notes, second edition")
        left.model.select(mask: "*.txt")
        interaction.formAnswers = [.values(["archive": .text(box.url("B/notes.zip").path)])]
        commands.perform(.packFiles)
        #expect(unzipList("B/notes.zip") == ["notes.txt", "todo.txt"])
        #expect(
            runTool("/usr/bin/unzip", ["-p", box.url("B/notes.zip").path, "notes.txt"], in: nil).output
                == "notes, second edition"
        )

        // With a ZIP open in the target panel, the proposal is that archive and the folder shown.
        right.show(box.url("A"))
        enter("tree.zip", in: right)
        enter("tree", in: right)
        enter("sub", in: right)
        left.focus()
        left.model.clearSelection()
        left.moveCursor(toName: "todo.txt")
        interaction.formAnswers = [.accept]
        commands.perform(.packFiles)
        #expect(interaction.forms.last?.first?.initialValue == .text(box.url("A/tree.zip").path + "/tree/sub"))
        #expect(right.names == ["data.bin", "inner.txt", "todo.txt"])
        #expect(
            isSound("A/tree.zip") && unzipList("A/tree.zip").contains("tree/sub/todo.txt")
                && unzipList("A/tree.zip").count == 7
        )
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

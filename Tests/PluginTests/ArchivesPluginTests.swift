import AFMContracts
import AFMKernel
@testable import ArchivesPlugin
import FileOperationsPlugin
import Foundation
import LocalFileSystemPlugin
import MacIntegrationPlugin
import NavigationPlugin
import TestSupport
import Testing

/// The archives plugin driven through its commands and through the commands of the plugins
/// it cooperates with (Enter, F5, F7, F8, rename), in panels without a window.
@MainActor @Suite struct ArchiveCommandsInPanels {
    let box: Sandbox
    let memory = MemoryFileSystem()
    let mac = MacIntegrationPlugin(launchesApplications: false)
    let archives = ArchivesPlugin(flushDelay: nil, launchesApplications: false)
    let settings = MemorySettings()
    let bench: TestBench

    var commands: CommandRegistry { bench.commands }
    var left: FakePanel { bench.left }
    var right: FakePanel { bench.right }
    var ui: ScriptedInteraction { bench.ui }

    init() throws {
        box = try Sandbox()
        try box.file("A/tree/readme.txt", String(repeating: "All work and no play makes Jack a dull boy.\n", count: 400))
        try box.file("A/tree/sub/inner.txt", "inner")
        try box.file("A/tree/sub/data.bin", String(repeating: "0123456789", count: 30_000))
        try box.folder("A/tree/hollow")
        try box.file("A/notes.txt", "notes")
        try box.file("A/todo.txt", "todo")
        try box.folder("B")
        #expect(runTool("/usr/bin/zip", ["-qr", "tree.zip", "tree"], in: box.url("A")).status == 0)
        bench = TestBench(plugins: [NavigationPlugin(), mac, FileOperationsPlugin(), archives], fileSystems: [LocalFileSystem(), memory],
                          left: box.url("A"), right: box.url("B"), settings: settings)
    }

    /// Enter on an item of the left panel.
    func enter(_ name: String, in panel: FakePanel? = nil) {
        let panel = panel ?? left
        panel.focus()
        panel.moveCursor(toName: name)
        commands.perform(.open)
    }

    func unzipList(_ path: String) -> [String] {
        runTool("/usr/bin/unzip", ["-Z1", box.url(path).path]).output.split(separator: "\n").map(String.init).sorted()
    }

    func isSound(_ path: String) -> Bool {
        runTool("/usr/bin/unzip", ["-tq", box.url(path).path]).status == 0
    }

    // MARK: Registration

    @Test func thePluginRegistersItsParts() {
        let kernel = bench.kernel
        #expect(kernel.fileSystems.all.map(\.scheme) == ["file", "mem", "zip", "archive"])
        #expect(kernel.keyBindings.conflicts.isEmpty)
        #expect(kernel.keyBindings.command(for: .f(5, .option)) == .packFiles && kernel.keyBindings.command(for: .f(9, .option)) == .unpackFiles)
        #expect(kernel.keyBindings.command(for: .f(9, [.option, .shift])) == "cm_TestArchive")
        #expect(kernel.keyBindings.command(for: .f(5, [.option, .shift])) == "cm_MoveToArchive")
        let files = kernel.menus.menus.first { $0.title == "Files" }?.items ?? []
        #expect(files.suffix(6) == [nil, .packFiles, "cm_MoveToArchive", .unpackFiles, "cm_TestArchive", "afm_OpenAsArchive"])
        #expect(kernel.menus.contextMenu(onItem: true).contains(.packFiles) && !kernel.menus.contextMenu(onItem: false).contains(.packFiles))
        #expect(kernel.toolbar.defaultLayout.compactMap { $0?.command }.filter { [.packFiles, .unpackFiles].contains($0) } == [.packFiles, .unpackFiles])
        let page = kernel.preferences.pages.first { $0.title == "Packer" }
        #expect(page?.preferences.count == 12 && page?.preferences.allSatisfy { $0.key.hasPrefix("archives.") } == true)
        #expect(commands.all.filter { ["cm_PackFiles", "cm_UnpackFiles", "cm_TestArchive"].contains($0.id.rawValue) }.count == 3)
    }

    // MARK: Archives as folders

    @Test func enterGoesIntoAnArchiveAndTheParentRowLeavesIt() {
        enter("tree.zip")
        #expect(left.failures.isEmpty && left.model.directory.scheme == "zip" && left.names == ["tree"])
        #expect(left.model.hasParentRow && bench.kernel.fileSystems.displayPath(left.model.directory) == box.url("A/tree.zip").path)
        enter("tree")
        #expect(left.names == ["hollow", "sub", "readme.txt"])
        #expect(left.model.items.last?.size == 17_600)
        enter("sub")
        #expect(left.names == ["data.bin", "inner.txt"])
        // Up, step by step; the last step leaves the archive with the cursor on it.
        commands.perform(.goToParent)
        #expect(left.model.cursorItem?.name == "sub")
        commands.perform(.goToParent)
        left.model.moveCursor(to: 0)
        commands.perform(.open)
        #expect(left.model.directory.isSameLocation(as: box.url("A")) && left.model.cursorItem?.name == "tree.zip")
        // Root from deep inside is the folder that holds the archive, again on the archive.
        commands.perform(.changeDirectory, .text(box.url("A/tree.zip").path + "/tree/sub"))
        #expect(left.names == ["data.bin", "inner.txt"])
        commands.perform(.goToRoot)
        #expect(left.model.directory.isSameLocation(as: box.url("A")) && left.model.cursorItem?.name == "tree.zip")
        commands.perform(.goBack)
        #expect(left.names == ["data.bin", "inner.txt"])
    }

    @Test func whichFilesOpenAsArchivesIsASetting() throws {
        // Other files go to their applications as before.
        enter("notes.txt")
        #expect(mac.opened.map(\.lastPathComponent) == ["notes.txt"] && left.model.directory.isFileURL)
        // An archive under another name is not entered by Enter, but by "Open as Archive".
        try FileManager.default.copyItem(at: box.url("A/tree.zip"), to: box.url("A/bundle.dat"))
        left.reload()
        enter("bundle.dat")
        #expect(mac.opened.count == 2)
        commands.perform("afm_OpenAsArchive")
        #expect(left.model.directory.scheme == "zip" && left.names == ["tree"])
        commands.perform(.goToParent)
        // A file that is no archive says so and leaves the panel where it was.
        left.moveCursor(toName: "notes.txt")
        commands.perform("afm_OpenAsArchive")
        #expect(left.failures.count == 1 && left.failures.first?.contains("not an archive") == true && left.model.directory.isFileURL)

        // The list of endings and the switch are read from the settings.
        let page = try #require(bench.kernel.preferences.pages.first { $0.title == "Packer" })
        settings.set("dat", forKey: "archives.extensions")
        page.onChange()
        enter("bundle.dat")
        // Enter decides by the name alone, so an unusual ending opens read-only.
        #expect(left.model.directory.scheme == "archive" && left.names == ["tree"])
        commands.perform(.goToParent)
        enter("tree.zip")
        #expect(left.model.directory.isFileURL && mac.opened.last?.lastPathComponent == "tree.zip")
        settings.set(false, forKey: "archives.openAsFolders")
        page.onChange()
        enter("bundle.dat")
        #expect(left.model.directory.isFileURL && mac.opened.last?.lastPathComponent == "bundle.dat")
    }

    @Test func enterOnAMemberShowsWhatTheArchiveKnows() {
        enter("tree.zip")
        enter("tree")
        ui.choiceAnswers = [1]
        enter("readme.txt")
        let sheet = ui.log.last ?? ""
        #expect(sheet.hasPrefix("choose: readme.txt") && sheet.contains("Size: 17,600 bytes") && sheet.contains("Packed:"))
        #expect(mac.opened.isEmpty)
        // "Unpack and Open" would hand a temporary copy to its application.
        ui.choiceAnswers = [0]
        enter("readme.txt")
        #expect(bench.jobService.titles.suffix(2) == ["Reading:", "Unpacking:"])
    }

    @Test func readOnlyArchivesWithholdTheCommandsThatChange() throws {
        #expect(runTool("/usr/bin/tar", ["-czf", "tree.tgz", "tree"], in: box.url("A")).status == 0)
        left.reload()
        enter("tree.tgz")
        #expect(left.model.directory.scheme == "archive" && left.names == ["tree"])
        enter("tree")
        left.moveCursor(toName: "readme.txt")
        #expect(!commands.isEnabled(.makeDirectory) && !commands.isEnabled(.delete) && !commands.isEnabled(.renameMove))
        #expect(commands.isEnabled(.copy) && commands.isEnabled(.unpackFiles))
        // In a ZIP they are there.
        commands.perform(.changeDirectory, .text(box.url("A/tree.zip").path + "/tree"))
        left.moveCursor(toName: "readme.txt")
        #expect(commands.isEnabled(.makeDirectory) && commands.isEnabled(.delete) && commands.isEnabled(.renameMove))
    }

    // MARK: File operations inside an archive

    @Test func copyOutOfAnArchiveWithTheCopyCommand() throws {
        enter("tree.zip")
        enter("tree")
        // One file to the target panel's folder, as the dialog proposes it.
        left.moveCursor(toName: "readme.txt")
        ui.promptAnswers = [.accept]
        commands.perform(.copy)
        #expect(ui.log.last == "prompt: Copy \"readme.txt\" to [\(box.url("B").path)/readme.txt]")
        #expect(box.read("B/readme.txt")?.count == 17_600)
        // A folder with everything in it.
        left.moveCursor(toName: "sub")
        ui.promptAnswers = [.accept]
        commands.perform(.copy)
        #expect(box.read("B/sub/inner.txt") == "inner" && box.read("B/sub/data.bin")?.count == 300_000)
        #expect(namesOnDisk(box.url("B")) == ["readme.txt", "sub"])
        right.reload()
        #expect(right.names == ["sub", "readme.txt"])
        #expect(archives.flushPendingChanges().isEmpty && isSound("A/tree.zip"))
    }

    @Test func copyIntoAnArchiveWithTheCopyCommand() throws {
        enter("tree.zip", in: left)
        enter("tree", in: left)
        enter("sub", in: left)
        right.show(box.url("A"))
        right.focus()
        right.model.select(mask: "*.txt")
        ui.promptAnswers = [.accept]
        commands.perform(.copy)
        // The target is written the way the archive panel shows its path.
        #expect(ui.log.last == "prompt: Copy 2 file(s) to [\(box.url("A/tree.zip").path)/tree/sub/*.*]")
        // The panel inside the archive shows the new files at once…
        #expect(left.names == ["data.bin", "inner.txt", "notes.txt", "todo.txt"])
        // …and the archive file holds them as soon as the job has put them under their names:
        // nothing is left waiting that a failed write could lose.
        let held = unzipList("A/tree.zip")
        #expect(Set(held.suffix(2)) == ["tree/sub/notes.txt", "tree/sub/todo.txt"], "\(held)")
        #expect(archives.flushPendingChanges().isEmpty && isSound("A/tree.zip"))
        #expect(unzipList("A/tree.zip") == held)
        #expect(runTool("/usr/bin/unzip", ["-p", box.url("A/tree.zip").path, "tree/sub/todo.txt"]).output == "todo")
        #expect(namesOnDisk(box.url("A")) == ["notes.txt", "todo.txt", "tree", "tree.zip"])

        // A whole folder, and a name collision answered with Skip.
        right.model.clearSelection()
        right.moveCursor(toName: "tree")
        ui.promptAnswers = [.accept]
        commands.perform(.copy)
        right.moveCursor(toName: "notes.txt")
        ui.promptAnswers = [.accept]
        ui.choiceAnswers = [2]
        commands.perform(.copy)
        #expect(ui.log.contains { $0.hasPrefix("choose: Overwrite:") })
        #expect(archives.flushPendingChanges().isEmpty && isSound("A/tree.zip"))
        #expect(unzipList("A/tree.zip").contains("tree/sub/tree/sub/data.bin"))
    }

    @Test func newFolderRenameAndDeleteInsideAnArchive() throws {
        enter("tree.zip")
        enter("tree")
        ui.promptAnswers = [.text("made/deeper")]
        commands.perform(.makeDirectory)
        #expect(left.names == ["hollow", "made", "sub", "readme.txt"] && left.model.cursorItem?.name == "made")

        left.moveCursor(toName: "readme.txt")
        commands.perform(.renameOnly, .text("LIESMICH.txt"))
        #expect(left.names == ["hollow", "made", "sub", "LIESMICH.txt"] && left.model.cursorItem?.name == "LIESMICH.txt")
        // F6 with a new name renames; into a folder of the same archive it moves.
        left.moveCursor(toName: "sub")
        ui.promptAnswers = [.text("unter")]
        commands.perform(.renameMove)
        left.moveCursor(toName: "LIESMICH.txt")
        ui.promptAnswers = [.text(box.url("A/tree.zip").path + "/tree/unter/")]
        commands.perform(.renameMove)
        #expect(left.names == ["hollow", "made", "unter"])

        // Delete: there is no Trash in an archive, so the question is the direct one; a
        // folder with contents is asked about once more.
        left.moveCursor(toName: "hollow")
        ui.choiceAnswers = [0]
        commands.perform(.delete)
        #expect(ui.log.contains { $0.hasPrefix("choose: Permanently delete") })
        left.moveCursor(toName: "made")
        ui.choiceAnswers = [0, 0]
        commands.perform(.delete)
        #expect(left.names == ["unter"])
        // Nothing of this has touched the archive file yet; one write brings it all.
        #expect(unzipList("A/tree.zip").contains("tree/readme.txt"))
        #expect(archives.flushPendingChanges().isEmpty && isSound("A/tree.zip"))
        #expect(unzipList("A/tree.zip") == ["tree/", "tree/unter/", "tree/unter/LIESMICH.txt", "tree/unter/data.bin", "tree/unter/inner.txt"])
        // Quitting writes what is still waiting.
        ui.promptAnswers = [.text("last")]
        commands.perform(.makeDirectory)
        archives.stop()
        #expect(unzipList("A/tree.zip").contains("tree/last/"))
    }

    // MARK: Pack

    @Test func packIntoTheTargetPanel() throws {
        left.moveCursor(toName: "tree")
        ui.formAnswers = [.accept]
        commands.perform(.packFiles)
        let fields = try #require(ui.forms.last)
        // The proposal: named after the operand, in the target panel's folder (spec 08 › Pack dialog).
        #expect(fields.first?.label == "Pack 1 file(s) to the archive" && fields.first?.initialValue == .text(box.url("B/tree.zip").path))
        #expect(fields.map(\.key) == ["archive", "format", "level", "paths", "recurse", "move", "separate", "skipBase", "tarFirst", "encrypt"])
        #expect(bench.jobService.titles == ["Packing:"] && ui.log.last == "form: Pack files")
        // No message; the archive appears in the target panel with the cursor on it.
        #expect(right.names == ["tree.zip"] && isSound("B/tree.zip"))
        #expect(unzipList("B/tree.zip") == ["tree/", "tree/hollow/", "tree/readme.txt", "tree/sub/", "tree/sub/data.bin", "tree/sub/inner.txt"])
        #expect(bench.jobService.reports.last?.itemsDone == 6 && bench.jobService.reports.last?.bytesDone == 317_605)
        #expect(box.exists("A/tree"))

        // Several items: named after the source folder. Another packer rewrites the ending.
        left.model.select(mask: "*.txt")
        ui.formAnswers = [.values(["format": .index(2), "level": .index(9)])]
        commands.perform(.packFiles)
        #expect(ui.forms.last?.first?.initialValue == .text(box.url("B/A.zip").path))
        #expect(right.names == ["A.tar.gz", "tree.zip"] && left.model.selection.isEmpty)
        #expect(runTool("/usr/bin/tar", ["-tzf", box.url("B/A.tar.gz").path]).output == "notes.txt\ntodo.txt\n")

        // A prefix names the packer too, and the name may be any.
        left.moveCursor(toName: "notes.txt")
        ui.formAnswers = [.values(["archive": .text("tar:" + box.url("B/deep/plain").path)])]
        commands.perform(.packFiles)
        #expect(runTool("/usr/bin/tar", ["-tf", box.url("B/deep/plain.tar").path]).output == "notes.txt\n")
        // An existing archive that is not a ZIP is replaced only after a question.
        ui.formAnswers = [.values(["archive": .text("tar:" + box.url("B/deep/plain").path)])]
        ui.choiceAnswers = [1]
        left.moveCursor(toName: "todo.txt")
        commands.perform(.packFiles)
        #expect(ui.log.contains { $0.hasPrefix("choose: Overwrite:") })
        #expect(runTool("/usr/bin/tar", ["-tf", box.url("B/deep/plain.tar").path]).output == "notes.txt\n")
    }

    @Test func packOptions() throws {
        // Without path names everything is stored flat; without recursion only the files directly inside.
        left.moveCursor(toName: "tree")
        ui.formAnswers = [.values(["paths": .flag(false), "archive": .text(box.url("B/flat.zip").path)])]
        commands.perform(.packFiles)
        #expect(unzipList("B/flat.zip") == ["data.bin", "inner.txt", "readme.txt"])
        ui.formAnswers = [.values(["recurse": .flag(false), "archive": .text(box.url("B/shallow.zip").path)])]
        commands.perform(.packFiles)
        #expect(unzipList("B/shallow.zip") == ["tree/", "tree/readme.txt"])

        // Separate archives; a single-file packer makes one per file by itself.
        left.model.select(mask: "*.txt")
        ui.formAnswers = [.values(["format": .index(5)])]
        commands.perform(.packFiles)
        #expect(namesOnDisk(box.url("B")) == ["flat.zip", "notes.txt.gz", "shallow.zip", "todo.txt.gz"])
        #expect(runTool("/usr/bin/gzip", ["-dc", box.url("B/todo.txt.gz").path]).output == "todo")
        left.model.clearSelection()
        left.moveCursor(toName: "tree")
        ui.formAnswers = [.values(["separate": .flag(true), "skipBase": .flag(true), "archive": .text(box.url("B/sep/").path + "/")])]
        commands.perform(.packFiles)
        #expect(unzipList("B/sep/tree.zip") == ["hollow/", "readme.txt", "sub/", "sub/data.bin", "sub/inner.txt"])
        // A folder into a single-file format: only through a TAR.
        ui.formAnswers = [.values(["format": .index(7), "archive": .text(box.url("B/x").path)])]
        commands.perform(.packFiles)
        #expect(ui.log.last == "inform: Packing failed!" && !box.exists("B/x.xz"))
        ui.formAnswers = [.values(["format": .index(7), "tarFirst": .flag(true), "archive": .text(box.url("B/x").path)])]
        commands.perform(.packFiles)
        #expect(runTool("/usr/bin/tar", ["-tJf", box.url("B/x.tar.xz").path]).output.split(separator: "\n").count == 6)

        // Move to archive deletes what was packed, after the archive is complete and tested.
        left.model.select(mask: "*.txt")
        ui.formAnswers = [.values(["archive": .text(box.url("B/moved.zip").path)])]
        commands.perform("cm_MoveToArchive")
        #expect(ui.forms.last?.first { $0.key == "move" }?.initialValue == .flag(true))
        #expect(unzipList("B/moved.zip") == ["notes.txt", "todo.txt"] && left.names == ["tree", "tree.zip"])
        left.moveCursor(toName: "tree")
        ui.formAnswers = [.values(["move": .flag(true), "archive": .text(box.url("B/gone.zip").path)])]
        commands.perform(.packFiles)
        #expect(!box.exists("A/tree") && isSound("B/gone.zip") && unzipList("B/gone.zip").count == 6)
    }

    @Test func packEncryptedAndIntoAnExistingArchive() throws {
        left.moveCursor(toName: "notes.txt")
        // The password is asked for twice; a mismatch asks again.
        ui.formAnswers = [.values(["encrypt": .flag(true)]), .values(["password": .text("one"), "repeat": .text("two")]),
                          .values(["password": .text("sesame"), "repeat": .text("sesame"), "legacy": .flag(true)])]
        commands.perform(.packFiles)
        #expect(ui.log.suffix(3) == ["form: Pack files", "form: Encrypt", "form: Encrypt"])
        #expect(runTool("/usr/bin/unzip", ["-p", "-P", "sesame", box.url("B/notes.zip").path]).output == "notes")
        #expect(runTool("/usr/bin/unzip", ["-tq", "-P", "wrong", box.url("B/notes.zip").path]).status != 0)
        // Only ZIP can.
        ui.formAnswers = [.values(["encrypt": .flag(true), "format": .index(1)])]
        commands.perform(.packFiles)
        #expect(ui.log.last == "inform: Only ZIP archives can be encrypted." && !box.exists("B/notes.tar"))

        // The same target again adds to the archive; a member packed again is replaced.
        try box.file("A/notes.txt", "notes, second edition")
        left.model.select(mask: "*.txt")
        ui.formAnswers = [.values(["archive": .text(box.url("B/notes.zip").path)])]
        commands.perform(.packFiles)
        #expect(unzipList("B/notes.zip") == ["notes.txt", "todo.txt"])
        #expect(runTool("/usr/bin/unzip", ["-p", box.url("B/notes.zip").path, "notes.txt"]).output == "notes, second edition")

        // With a ZIP open in the target panel, the proposal is that archive and the folder shown.
        right.show(box.url("A"))
        enter("tree.zip", in: right)
        enter("tree", in: right)
        enter("sub", in: right)
        left.focus()
        left.model.clearSelection()
        left.moveCursor(toName: "todo.txt")
        ui.formAnswers = [.accept]
        commands.perform(.packFiles)
        #expect(ui.forms.last?.first?.initialValue == .text(box.url("A/tree.zip").path + "/tree/sub"))
        #expect(right.names == ["data.bin", "inner.txt", "todo.txt"])
        #expect(isSound("A/tree.zip") && unzipList("A/tree.zip").contains("tree/sub/todo.txt") && unzipList("A/tree.zip").count == 7)
    }

    // MARK: Unpack and test

    @Test func unpackArchivesIntoTheTargetPanel() throws {
        left.moveCursor(toName: "tree.zip")
        ui.formAnswers = [.accept]
        commands.perform(.unpackFiles)
        let fields = try #require(ui.forms.last)
        #expect(fields.map(\.key) == ["target", "mask", "paths", "separate", "overwrite"])
        #expect(fields.first?.initialValue == .text(box.url("B").path) && fields.first?.label == "Unpack specific files from archive to:")
        #expect(snapshot(box.url("B/tree")) == snapshot(box.url("A/tree")) && right.names == ["tree"])
        #expect(bench.jobService.reports.last?.bytesDone == 317_605)

        // Again: every existing file is asked about; "Skip all" leaves them.
        try box.file("B/tree/readme.txt", "changed here")
        ui.formAnswers = [.accept]
        ui.choiceAnswers = [3]
        commands.perform(.unpackFiles)
        #expect(ui.log.filter { $0.hasPrefix("choose: Overwrite:") }.count == 1 && box.read("B/tree/readme.txt") == "changed here")
        ui.formAnswers = [.values(["overwrite": .flag(true)])]
        commands.perform(.unpackFiles)
        #expect(box.read("B/tree/readme.txt")?.count == 17_600)

        // A mask, without paths, into a folder per archive; several archives at once.
        #expect(runTool("/usr/bin/tar", ["-cjf", "second.tar.bz2", "notes.txt", "todo.txt"], in: box.url("A")).status == 0)
        left.reload()
        left.model.select(mask: "*.zip *.bz2")
        ui.formAnswers = [.values(["mask": .text("*.txt"), "paths": .flag(false), "separate": .flag(true), "target": .text(box.url("B/out").path)])]
        commands.perform(.unpackFiles)
        #expect(namesOnDisk(box.url("B/out")) == ["second", "tree"])
        #expect(namesOnDisk(box.url("B/out/tree")) == ["inner.txt", "readme.txt"] && namesOnDisk(box.url("B/out/second")) == ["notes.txt", "todo.txt"])
        #expect(left.model.selection.isEmpty)

        // Something that is no archive is reported; the rest is unpacked.
        left.model.select(mask: "notes.txt *.bz2")
        ui.formAnswers = [.values(["target": .text(box.url("B/mixed").path)])]
        commands.perform(.unpackFiles)
        #expect(ui.log.last == "inform: Some files could not be unpacked!" && namesOnDisk(box.url("B/mixed")) == ["notes.txt", "todo.txt"])
        // An empty target is the archive's own folder.
        left.model.clearSelection()
        left.moveCursor(toName: "second.tar.bz2")
        try FileManager.default.removeItem(at: box.url("A/notes.txt"))
        ui.formAnswers = [.values(["target": .text(""), "overwrite": .flag(true)])]
        commands.perform(.unpackFiles)
        #expect(box.read("A/notes.txt") == "notes")
    }

    @Test func unpackFromInsideAnArchive() throws {
        enter("tree.zip")
        enter("tree")
        // The marked entries, folders with everything in them, relative to the folder shown.
        left.model.select(mask: "sub hollow")
        ui.formAnswers = [.accept]
        commands.perform(.unpackFiles)
        #expect(ui.forms.last?.first?.label == "Unpack 2 file(s) to")
        #expect(namesOnDisk(box.url("B")) == ["hollow", "sub"] && namesOnDisk(box.url("B/sub")) == ["data.bin", "inner.txt"])
        // Nothing marked: everything below the folder shown that fits the mask.
        left.model.clearSelection()
        ui.formAnswers = [.values(["mask": .text("*.txt"), "target": .text(box.url("B/texts").path)])]
        commands.perform(.unpackFiles)
        #expect(namesOnDisk(box.url("B/texts")) == ["readme.txt", "sub"] && namesOnDisk(box.url("B/texts/sub")) == ["inner.txt"])
    }

    @Test func testArchivesReportsWhatIsDamaged() throws {
        #expect(runTool("/usr/bin/zip", ["-qr0", "stored.zip", "tree"], in: box.url("A")).status == 0)
        #expect(runTool("/usr/bin/tar", ["-czf", "tree.tgz", "tree"], in: box.url("A")).status == 0)
        left.reload()
        left.model.select(mask: "*.zip *.tgz")
        commands.perform("cm_TestArchive")
        #expect(ui.log.last == "inform: Archive test" && bench.jobService.titles == ["Testing:"])

        var bytes = try Data(contentsOf: box.url("A/stored.zip"))
        let position = try #require(bytes.range(of: Data("0123456789012345".utf8))).lowerBound + 5000
        bytes[position] = 0x58
        try bytes.write(to: box.url("A/stored.zip"))
        commands.perform("cm_TestArchive")
        #expect(ui.log.last == "inform: Errors found in archive!")
        // Inside an archive the archive itself is tested.
        left.model.clearSelection()
        enter("tree.zip")
        commands.perform("cm_TestArchive")
        #expect(ui.log.last == "inform: Archive test")
    }

    // MARK: Other file systems

    @Test func archivesOnAnotherFileSystemOpenTheSameWay() throws {
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
        ui.promptAnswers = [.text(box.url("B").path + "/")]
        commands.perform(.copy)
        // A plain path typed inside an archive is a place on the disk, wherever the archive is.
        #expect(box.exists("B/readme.txt") && !memory.exists(box.url("B").path + "/readme.txt"))
        // New folder inside, written back to where the archive lives.
        ui.promptAnswers = [.text("made")]
        commands.perform(.makeDirectory)
        #expect(left.names.contains("made") && archives.flushPendingChanges().isEmpty)
        commands.perform(.goToParent)
        commands.perform(.goToParent)
        #expect(left.model.directory.isSameLocation(as: memory.url("/store")) && left.model.cursorItem?.name == "tree.zip")
        #expect(left.model.cursorItem?.size != Int64(bytes.count))
        // Pack onto that file system.
        left.show(box.url("A"))
        right.show(memory.url("/store"))
        left.focus()
        left.moveCursor(toName: "notes.txt")
        ui.formAnswers = [.accept]
        commands.perform(.packFiles)
        #expect(ui.forms.last?.first?.initialValue == .text("mem:/store/notes.zip") && right.names == ["notes.zip", "tree.zip"])
    }
}

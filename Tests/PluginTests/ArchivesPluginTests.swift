import AFMContracts
import AFMKernel
import Foundation
import MacIntegrationPlugin
import TestSupport
import Testing

/// The archives plugin in panels: its parts, archives entered and left like folders, and the files
/// Enter opens as archives.
@MainActor
@Suite
internal struct ArchivesPluginTests {
    /// The panels, the plugins and the sandbox.
    private let fixture: ArchivePanelsFixture

    /// The sandbox that holds `A` and `B`.
    private var box: Sandbox { fixture.box }
    /// The Mac integration, which notes what it would open.
    private var mac: MacIntegrationPlugin { fixture.mac }
    /// The settings of the bench.
    private var settings: MemorySettings { fixture.settings }
    /// The kernel with the plugins and the two panels.
    private var bench: TestBench { fixture.bench }
    /// The commands of the kernel.
    private var commands: CommandRegistry { fixture.commands }
    /// The left panel, on `A` at the start.
    private var left: FakePanel { fixture.left }
    /// The scripted answers of the user, and what was asked.
    private var interaction: ScriptedInteraction { fixture.interaction }

    /// A fresh fixture for each test.
    internal init() throws {
        fixture = try ArchivePanelsFixture()
    }

    /// The plugin registers its file systems, keys, menu items, toolbar buttons, preferences and commands.
    @Test
    internal func thePluginRegistersItsParts() {
        let kernel = bench.kernel
        #expect(kernel.fileSystems.all.map(\.scheme) == ["file", "mem", "zip", "archive"])
        #expect(kernel.keyClashes.isEmpty)
        #expect(
            kernel.keyBindings.command(for: .f(5, .option)) == .packFiles
                && kernel.keyBindings.command(for: .f(9, .option)) == .unpackFiles
        )
        #expect(kernel.keyBindings.command(for: .f(9, [.option, .shift])) == "cm_TestArchive")
        #expect(kernel.keyBindings.command(for: .f(5, [.option, .shift])) == "cm_MoveToArchive")
        let files = kernel.menus.menus.first { $0.title == "Files" }?.items ?? []
        #expect(
            files.suffix(6) == [
                nil, .packFiles, "cm_MoveToArchive", .unpackFiles, "cm_TestArchive", "afm_OpenAsArchive"
            ]
        )
        #expect(
            kernel.menus.contextMenu(onItem: true).contains(.packFiles)
                && !kernel.menus.contextMenu(onItem: false).contains(.packFiles)
        )
        #expect(
            kernel.toolbar.defaultLayout.compactMap { $0?.command }.filter { [.packFiles, .unpackFiles].contains($0) }
                == [.packFiles, .unpackFiles]
        )
        let page = kernel.preferences.pages.first { $0.title == "Packer" }
        #expect(page?.preferences.count == 12 && page?.preferences.allSatisfy { $0.key.hasPrefix("archives.") } == true)
        #expect(
            commands.all.filter { ["cm_PackFiles", "cm_UnpackFiles", "cm_TestArchive"].contains($0.id.rawValue) }.count
                == 3
        )
    }

    // MARK: Archives as folders

    /// Enter goes into an archive and its folders; going up, to the root or back leaves it with the cursor on it.
    @Test
    internal func enterGoesIntoAnArchiveAndTheParentRowLeavesIt() {
        enter("tree.zip")
        #expect(left.failures.isEmpty && left.model.directory.scheme == "zip" && left.names == ["tree"])
        #expect(
            left.model.hasParentRow
                && bench.kernel.fileSystems.displayPath(left.model.directory) == box.url("A/tree.zip").path
        )
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

    /// Which files Enter opens as archives follows the settings; Open as Archive opens any archive by its contents.
    @Test
    internal func whichFilesOpenAsArchivesIsASetting() throws {
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
        #expect(
            left.failures.count == 1 && left.failures.first?.contains("not an archive") == true
                && left.model.directory.isFileURL
        )

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

    /// Enter on a member shows what the archive knows of it, and can unpack and open it.
    @Test
    internal func enterOnAMemberShowsWhatTheArchiveKnows() {
        enter("tree.zip")
        enter("tree")
        interaction.choiceAnswers = [1]
        enter("readme.txt")
        let sheet = interaction.log.last ?? ""
        #expect(
            sheet.hasPrefix("choose: readme.txt") && sheet.contains("Size: 17,600 bytes") && sheet.contains("Packed:")
        )
        #expect(mac.opened.isEmpty)
        // "Unpack and Open" would hand a temporary copy to its application.
        interaction.choiceAnswers = [0]
        enter("readme.txt")
        #expect(bench.jobService.titles.suffix(2) == ["Reading:", "Unpacking:"])
    }

    /// In a read-only archive the commands that change are disabled; in a ZIP they are there.
    @Test
    internal func readOnlyArchivesWithholdTheCommandsThatChange() {
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

    /// Enter on an item of the left panel.
    private func enter(_ name: String) {
        fixture.enter(name)
    }
}

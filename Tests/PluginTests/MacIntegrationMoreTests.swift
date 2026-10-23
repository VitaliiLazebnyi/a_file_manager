import AFMContracts
import AFMKernel
import AppKit
import LocalFileSystemPlugin
import NavigationPlugin
import SelectionPlugin
import TestSupport
import Testing

@testable import MacIntegrationPlugin

/// What the Mac-integration plugin hands to other applications, read from its `opened` list
/// and its log.
///
/// Nothing is started and no system panel is shown.
@MainActor
@Suite
internal struct MacIntegrationMoreTests {
    /// The folder on disk: `A` with `notes.txt`, `photo.png` and `sub`, and an empty `B`.
    internal let box: Sandbox
    private let scratch = ScratchPasteboard()
    /// The pasteboard the plugin copies to, the test's own.
    internal var pasteboard: NSPasteboard { scratch.pasteboard }
    /// The plugin, which starts nothing and records what it would have opened.
    internal let mac: MacIntegrationPlugin
    /// A file system that is not local, with `/M/remote.txt`.
    internal let memory = MemoryFileSystem()
    /// The kernel with navigation, selection and the plugin; `A` on the left, `B` on the right.
    internal let bench: TestBench

    /// The kernel's commands.
    internal var commands: CommandRegistry { bench.commands }
    /// The scripted answers to the plugin's questions, and the log of them.
    internal var interaction: ScriptedInteraction { bench.interaction }

    /// Makes the folders and starts the kernel; text files open with two applications, others with none.
    internal init() throws {
        box = try Sandbox()
        try box.file("A/notes.txt", "hello")
        try box.file("A/photo.png")
        try box.folder("A/sub")
        try box.folder("B")
        memory.addFile("/M/remote.txt", "far")
        let apps = [
            URL(fileURLWithPath: "/Applications/First Editor.app"), URL(fileURLWithPath: "/Applications/Second.app")
        ]
        mac = MacIntegrationPlugin(launchesApplications: false, pasteboard: scratch.pasteboard) { file in
            file.pathExtension == "txt" ? apps : []
        }
        bench = TestBench(
            plugins: [NavigationPlugin(), SelectionPlugin(), mac],
            fileSystems: [LocalFileSystem(), memory],
            left: box.url("A"),
            right: box.url("B")
        )
    }

    /// The path of an item of `A`.
    internal func path(_ name: String) -> String { box.url("A/" + name).path }

    /// F4 opens the file under the cursor with the editor the preference names; folders and
    /// files that are not local are not edited.
    @Test
    internal func f4UsesTheEditorOfThePreferences() {
        let page = bench.kernel.preferences.pages.first { $0.title == "Edit (F4)" }
        #expect(page?.preferences.map(\.key) == [MacIntegrationPlugin.editorKey])
        #expect(bench.kernel.keyBindings.command(for: .f(4)) == .edit && bench.kernel.keyClashes.isEmpty)
        bench.left.moveCursor(toName: "notes.txt")
        commands.perform(.edit)
        // The editor is chosen by name, by path or by picking the application.
        commands.perform(MacIntegrationPlugin.chooseEditor, .text("BBEdit"))
        commands.perform(.edit)
        commands.perform(MacIntegrationPlugin.chooseEditor, .location(URL(fileURLWithPath: "/Applications/Xcode.app")))
        commands.perform(.edit, .location(box.url("A/photo.png")))
        #expect(
            mac.log == [
                "edit TextEdit " + path("notes.txt"), "edit BBEdit " + path("notes.txt"),
                "edit /Applications/Xcode.app " + path("photo.png")
            ]
        )
        #expect(mac.opened.map(\.lastPathComponent) == ["notes.txt", "notes.txt", "photo.png"])
        // Folders and files elsewhere are not edited.
        bench.left.moveCursor(toName: "sub")
        #expect(!commands.isEnabled(.edit))
        bench.left.show(memory.url("/M"))
        bench.left.moveCursor(toName: "remote.txt")
        #expect(
            !commands.isEnabled(.edit) && !commands.isEnabled(MacIntegrationPlugin.openWith)
                && !commands.isEnabled(MacIntegrationPlugin.quickLook)
        )
    }

    /// The editor preference is a name, a path or a bundle identifier; what cannot be found is TextEdit.
    @Test
    internal func theEditorPreferenceNamesAnApplication() {
        let textEdit = "/System/Applications/TextEdit.app"
        #expect(MacIntegrationPlugin.editorApplication(named: "TextEdit").path == textEdit)
        #expect(MacIntegrationPlugin.editorApplication(named: " TextEdit.app ").path == textEdit)
        #expect(
            MacIntegrationPlugin.editorApplication(named: "/System/Applications/Preview.app").path
                == "/System/Applications/Preview.app"
        )
        // What cannot be found falls back to TextEdit, so F4 always opens something.
        #expect(MacIntegrationPlugin.editorApplication(named: "").path == textEdit)
        #expect(MacIntegrationPlugin.editorApplication(named: "/nowhere/Missing.app").path == textEdit)
        #expect(MacIntegrationPlugin.editorApplication(named: "No Such Editor 12345").path == textEdit)
        #expect(MacIntegrationPlugin.editorApplication(named: "~/No Such Folder 12345/Missing.app").path == textEdit)
    }

    /// A leading `~` stands for the user's home folder and `~name` for that user's, as in the
    /// shell; a user who does not exist leaves the path as it is.
    @Test
    internal func aTildeIsAHomeFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(MacIntegrationPlugin.expandingTilde(in: "~/Editors/A.app") == home + "/Editors/A.app")
        #expect(MacIntegrationPlugin.expandingTilde(in: "~") == home)
        #expect(MacIntegrationPlugin.expandingTilde(in: "~root/A.app") == "/var/root/A.app")
        #expect(MacIntegrationPlugin.expandingTilde(in: "~nosuchuser12345/A.app") == "~nosuchuser12345/A.app")
        #expect(MacIntegrationPlugin.expandingTilde(in: "/Applications/A.app") == "/Applications/A.app")
    }

    /// Open With lists the applications that open the file, the default first, and opens the
    /// one picked; Enter and Open with Default Application go to the default one.
    @Test
    internal func openWithOffersTheApplicationsForTheFile() {
        bench.left.moveCursor(toName: "notes.txt")
        interaction.formAnswers = [.values(["row": .index(1)]), .cancel, .values(["row": .index(2)])]
        commands.perform(MacIntegrationPlugin.openWith)
        #expect(interaction.forms.count == 1)
        if case .list(let rows, let selected)? = interaction.forms.first?.first?.kind {
            #expect(rows == ["First Editor (default)", "Second", "Other…"] && selected == 0)
        } else {
            Issue.record("Open With shows no list")
        }
        // Cancelled, and "Other…" without a panel to pick from: nothing is opened.
        commands.perform(MacIntegrationPlugin.openWith)
        commands.perform(MacIntegrationPlugin.openWith)
        #expect(mac.log == ["open-with Second " + path("notes.txt")] && mac.opened == [box.url("A/notes.txt")])

        // Enter goes to the default application through the general opener, and so does the command.
        commands.perform(.open)
        bench.left.moveCursor(toName: "sub")
        commands.perform(MacIntegrationPlugin.openWithDefault)
        #expect(
            mac.opened.map(\.lastPathComponent) == ["notes.txt", "notes.txt", "sub"]
                && mac.log.last == "open " + path("sub")
        )
    }

    /// Quick Look, Share and Copy as Pathname act on the marked items, or the one under the cursor,
    /// and Copy as Pathname on the folder itself without either.
    @Test
    internal func quickLookShareAndPathnameTakeTheOperands() {
        bench.left.moveCursor(toName: "photo.png")
        commands.perform(MacIntegrationPlugin.quickLook)
        commands.perform(.selectAll)
        commands.perform(MacIntegrationPlugin.share)
        commands.perform(MacIntegrationPlugin.copyAsPathname)
        #expect(
            mac.log == [
                "quicklook " + path("photo.png"),
                "share " + [path("sub"), path("notes.txt"), path("photo.png")].joined(separator: " ")
            ]
        )
        #expect(
            pasteboard.string(forType: .string)
                == [path("sub"), path("notes.txt"), path("photo.png")].joined(separator: "\n")
        )
        #expect(
            !commands.isChecked(MacIntegrationPlugin.quickLook)
                && bench.kernel.keyBindings.command(for: .cmd("y")) == MacIntegrationPlugin.quickLook
        )
        // With nothing to act on, the folder's own path is copied.
        bench.left.show(box.url("B"))
        commands.perform(MacIntegrationPlugin.copyAsPathname)
        #expect(
            pasteboard.string(forType: .string) == box.url("B").path && !commands.isEnabled(MacIntegrationPlugin.share)
        )
        let context = bench.kernel.menus.contextMenu(onItem: true).compactMap(\.self)
        #expect(context.contains(MacIntegrationPlugin.openWith) && context.contains(MacIntegrationPlugin.editTags))
        #expect(!bench.kernel.menus.contextMenu(onItem: false).contains(MacIntegrationPlugin.share))
    }

    /// Finder tags are typed separated by commas; the dialog proposes the file's tags, Cancel
    /// keeps them and an empty line removes them.
    @Test
    internal func finderTagsAreReadEditedAndWritten() {
        #expect(
            MacIntegrationPlugin.tags(from: " Red, Work ,, Red,") == ["Red", "Work"]
                && MacIntegrationPlugin.tags(from: " ").isEmpty
        )
        bench.left.moveCursor(toName: "notes.txt")
        interaction.promptAnswers = [.text("Work, Red"), .cancel, .text("")]
        commands.perform(MacIntegrationPlugin.editTags)
        #expect(MacIntegrationPlugin.tags(of: box.url("A/notes.txt")) == ["Work", "Red"])
        #expect(
            interaction.log == ["prompt: Finder tags of “notes.txt”: []"]
                && mac.log == ["tags " + path("notes.txt") + ": Work, Red"]
        )
        #expect(bench.jobService.titles == ["Reading tags", "Setting tags"])
        // The dialog proposes the tags the file has; Cancel keeps them, an empty line removes them.
        commands.perform(MacIntegrationPlugin.editTags)
        #expect(
            interaction.log.last == "prompt: Finder tags of “notes.txt”: [Work, Red]"
                && MacIntegrationPlugin.tags(of: box.url("A/notes.txt")).count == 2
        )
        commands.perform(.selectAll)
        commands.perform(MacIntegrationPlugin.editTags)
        #expect(
            interaction.log.last == "prompt: Finder tags of 3 items: []"
                && MacIntegrationPlugin.tags(of: box.url("A/notes.txt")).isEmpty
        )
    }
}

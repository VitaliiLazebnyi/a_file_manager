import AFMContracts
import AFMKernel
import AppKit
import MacIntegrationPlugin
import TestSupport
import Testing

/// The commands on the local disk: the Trash, the editor, the openers and the clipboard.
extension PluginCommandTests {
    /// New Text File makes an empty file, puts the cursor on it and hands it to the editor.
    @Test
    internal func newTextFileIsCreatedAndHandedToTheEditor() throws {
        let box = try Sandbox()
        try box.file("A/readme.md", "r")
        try box.folder("B")
        showOnDisk(box)
        user.promptAnswers = [.text("notes.txt")]
        commands.perform(.newTextFile)
        #expect(box.read("A/notes.txt")?.isEmpty == true && left.model.cursorItem?.name == "notes.txt")
        #expect(mac.opened.map(\.lastPathComponent) == ["notes.txt"])
    }

    /// Open and Edit hand a file to the openers; a file no plugin opens is rejected and cannot be edited.
    @Test
    internal func openingAFileGoesToTheOpeners() throws {
        let box = try Sandbox()
        try box.file("A/readme.md", "r")
        try box.folder("B")
        showOnDisk(box)
        left.moveCursor(toName: "readme.md")
        commands.perform(.open)
        commands.perform(.edit)
        commands.perform(.edit, .location(box.url("A/other.txt")))
        #expect(mac.opened.map(\.lastPathComponent) == ["readme.md", "readme.md", "other.txt"])

        // A file no plugin opens: the command is rejected, nothing else happens.
        var rejections = 0
        commands.onRejected = { rejections += 1 }
        left.show(memory.url("/A"))
        left.moveCursor(toName: "one.txt")
        commands.perform(.open)
        #expect(rejections == 1 && !commands.isEnabled(.edit))
    }

    /// On the local disk Delete asks about moving to the Trash, and a no keeps the file.
    @Test
    internal func deleteMovesToTheTrashOnTheLocalDisk() throws {
        let box = try Sandbox()
        try box.file("A/readme.md", "r")
        try box.folder("B")
        showOnDisk(box)
        left.moveCursor(toName: "readme.md")
        user.choiceAnswers = [1]
        commands.perform(.delete)
        #expect(
            user.log.contains("choose: Test / Do you really want to move the selected file readme.md to the Trash?")
        )
        #expect(box.exists("A/readme.md"))
    }

    /// The clipboard copies to the other panel, renames a copy pasted next to its original, and moves once after a cut.
    @Test
    internal func clipboardCopiesMovesAndRenamesSelfCopies() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "1")
        try box.file("A/docs/in.txt", "2")
        try box.folder("B")
        showOnDisk(box)
        #expect(!commands.isEnabled(.pasteFromClipboard))

        commands.perform(.selectAll)
        commands.perform(.copyToClipboard)
        #expect(left.model.selection.count == 2)
        right.focus()
        commands.perform(.pasteFromClipboard)
        #expect(box.read("B/one.txt") == "1" && box.read("B/docs/in.txt") == "2" && right.names == ["docs", "one.txt"])

        // Pasted next to the original, a copy gets a new name.
        left.focus()
        commands.perform(.pasteFromClipboard)
        #expect(box.read("A/one (2).txt") == "1" && box.exists("A/docs (2)/in.txt"))

        // Cut and paste moves, once.
        commands.perform(.unselectAll)
        left.moveCursor(toName: "one (2).txt")
        commands.perform(.cutToClipboard)
        right.focus()
        commands.perform(.pasteFromClipboard)
        #expect(box.read("B/one (2).txt") == "1" && !box.exists("A/one (2).txt"))
        #expect(left.names == ["docs", "docs (2)", "one.txt"])

        commands.perform(.copyFullNames)
        #expect(pasteboard.string(forType: .string) == box.url("B").path + "/one (2).txt")
    }

    /// Files in memory cannot be copied or cut to the clipboard; their full names can.
    @Test
    internal func theClipboardCarriesLocalFilesOnly() {
        left.moveCursor(toName: "one.txt")
        #expect(!commands.isEnabled(.copyToClipboard) && !commands.isEnabled(.cutToClipboard))
        commands.perform(.copyFullNames)
        #expect(pasteboard.string(forType: .string) == "mem:/A/one.txt")
    }
}

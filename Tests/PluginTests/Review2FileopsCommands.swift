import AFMContracts
import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import SelectionPlugin
import TestSupport
import Testing
import VirtualFoldersPlugin

@testable import ClipboardPlugin
@testable import FileOperationsPlugin
@testable import FilePropertiesPlugin

/// The commands of the file operations and the clipboard with branch views, lists of files, large selections and
/// misleading names.
@MainActor
@Suite
internal struct Review2FileopsCommands {
    /// A scratch folder with d/a.txt, d/b.txt, d/sub/c.txt and an empty folder t.
    internal let box: Sandbox
    private let scratch = ScratchPasteboard()
    /// A pasteboard of the test's own, in place of the general one.
    internal var pasteboard: NSPasteboard { scratch.pasteboard }
    /// The plugin that makes branch views and lists of files.
    internal let virtual = VirtualFoldersPlugin()
    /// The program with d in the left panel and t in the right one.
    internal let bench: TestBench

    /// The stand-in for the user: answers the questions and notes them in its log.
    internal var interaction: ScriptedInteraction { bench.interaction }
    /// The program's commands.
    internal var commands: CommandRegistry { bench.commands }

    /// The scratch folder, and the program with the file-operation, clipboard, selection and virtual-folder plugins.
    internal init() throws {
        box = try Sandbox()
        try box.file("d/a.txt", "precious")
        try box.file("d/b.txt", "second")
        try box.file("d/sub/c.txt", "deep")
        try box.folder("t")
        bench = TestBench(
            plugins: [
                virtual, FileOperationsPlugin(), ClipboardPlugin(pasteboard: scratch.pasteboard), SelectionPlugin()
            ],
            fileSystems: [LocalFileSystem()],
            left: box.url("d"),
            right: box.url("t")
        )
    }

    /// The file URLs on the pasteboard, one for each item that has one.
    private func urlsOnPasteboard() -> [URL] {
        (pasteboard.pasteboardItems ?? [])
            .compactMap { item in item.string(forType: .fileURL).flatMap { URL(string: $0) } }
    }

    /// The branch view of the folder at `path` in the scratch folder.
    private func branch(of path: String) throws -> URL {
        try #require(virtual.fileSystem).branch(of: box.url(path))
    }

    // F001, F018: what Paste after Cut does in a branch view.
    /// Moving files into the branch view they are shown in changes nothing and says nothing; a file of a subfolder
    /// is moved up.
    @Test
    internal func movingFilesIntoTheBranchViewTheyAreShownInChangesNothing() throws {
        let transfers = try #require(bench.kernel.services.find((any FileTransferService).self))
        var ended = false
        transfers.transfer(
            .move,
            [box.url("d/a.txt"), box.url("d/b.txt")],
            into: try branch(of: "d"),
            renamingSelfCopies: false
        ) { _ in ended = true }
        #expect(ended && box.read("d/a.txt") == "precious" && box.read("d/b.txt") == "second")
        #expect(namesOnDisk(box.url("d")) == ["a.txt", "b.txt", "sub"])
        // Nothing to do is nothing to tell.
        #expect(!interaction.log.contains { $0.hasPrefix("inform") })
        // A file of a subfolder is moved up into the folder of the branch, by a rename.
        transfers.transfer(.move, [box.url("d/sub/c.txt")], into: try branch(of: "d"), renamingSelfCopies: false) { _ in
            // The test looks at the files.
        }
        #expect(box.read("d/c.txt") == "deep" && !box.exists("d/sub/c.txt"))
    }

    /// A copy pasted into a branch view of its own folder arrives in the real folder under a new name.
    @Test
    internal func pastingACopyIntoABranchViewGivesItANewNameInTheRealFolder() throws {
        let transfers = try #require(bench.kernel.services.find((any FileTransferService).self))
        transfers.transfer(.copy, [box.url("d/a.txt")], into: try branch(of: "d"), renamingSelfCopies: true) { _ in
            // The test looks at the files.
        }
        #expect(
            namesOnDisk(box.url("d")) == ["a (2).txt", "a.txt", "b.txt", "sub"] && box.read("d/a.txt") == "precious"
        )
    }

    /// Pasting into a list of files is refused with a message, and nothing is written anywhere.
    @Test
    internal func nothingCanBePastedIntoAListOfFiles() throws {
        let transfers = try #require(bench.kernel.services.find((any FileTransferService).self))
        let list = try #require(virtual.fileSystem)
            .register(
                files: [box.url("d/a.txt")],
                title: "Found",
                origin: box.url("d")
            )
        transfers.transfer(.copy, [box.url("d/b.txt")], into: list, renamingSelfCopies: false) { _ in
            // The test looks at the files and the message.
        }
        #expect(interaction.log.contains { $0.hasPrefix("inform") && $0.contains("list of files") })
        #expect(namesOnDisk(box.root) == ["d", "t"] && namesOnDisk(box.url("t")).isEmpty)
    }

    // F026
    /// F5 towards a branch view proposes and fills the real folder.
    @Test
    internal func copyingTowardsABranchViewGoesIntoTheRealFolder() throws {
        bench.right.show(try branch(of: "t"))
        bench.left.moveCursor(toName: "a.txt")
        interaction.promptAnswers = [.accept]
        commands.perform(.copy)
        // The proposal names the real folder; no folder called "t (branch)" appears.
        #expect(interaction.log.contains("prompt: Copy \"a.txt\" to [\(box.url("t").path)/a.txt]"))
        #expect(box.read("t/a.txt") == "precious" && namesOnDisk(box.root) == ["d", "t"])
    }

    /// F5 towards a list of files proposes the bare name, never a folder named after the list.
    @Test
    internal func aListOfFilesIsNotOfferedAsATarget() throws {
        bench.right.show(
            try #require(virtual.fileSystem)
                .register(
                    files: [box.url("d/a.txt")],
                    title: "Found",
                    origin: box.url("d")
                )
        )
        bench.left.moveCursor(toName: "b.txt")
        interaction.promptAnswers = [.accept]
        commands.perform(.copy)
        // The proposal is the name alone, never "Found (list 7)/b.txt", which would read as a folder to make.
        #expect(
            interaction.log.contains("prompt: Copy \"b.txt\" to [b.txt]")
                && interaction.log.contains("inform: You cannot copy a file to itself!")
        )
        #expect(namesOnDisk(box.root) == ["d", "t"] && namesOnDisk(box.url("d")) == ["a.txt", "b.txt", "sub"])
    }

    // F001: a rename typed in a branch view.
    /// F6 with a new letter case in a branch view renames the same file.
    @Test
    internal func renamingInABranchViewWithF6IsARename() throws {
        bench.left.show(try branch(of: "d"))
        bench.left.moveCursor(toName: "a.txt")
        var info = stat()
        #expect(lstat(box.url("d/a.txt").path, &info) == 0)
        let before = info.st_ino
        interaction.promptAnswers = [.text("A.TXT")]
        commands.perform(.renameMove)
        #expect(namesOnDisk(box.url("d")) == ["A.TXT", "b.txt", "sub"] && box.read("d/A.TXT") == "precious")
        #expect(lstat(box.url("d/A.TXT").path, &info) == 0 && info.st_ino == before)
    }

    // F056, F006: several items renamed with one mask.
    /// Renaming several items to one name asks once, and Overwrite All costs no file its contents.
    @Test
    internal func aRenameOfSeveralItemsToOneNameKeepsThemAllAndAsksOnce() {
        bench.left.moveCursor(toName: "a.txt")
        commands.perform(.selectAll)
        bench.left.model.setSelected(false, names: ["sub"])
        interaction.formAnswers = [.values(["mask": .text("same.txt")])]
        // "Overwrite all" to the one question; it must not cost the first file its contents.
        interaction.choiceAnswers = [1]
        commands.perform(.renameOnly)
        #expect(namesOnDisk(box.url("d")) == ["same (2).txt", "same.txt", "sub"])
        #expect(Set([box.read("d/same.txt"), box.read("d/same (2).txt")]) == ["precious", "second"])
        #expect(interaction.log.filter { $0.hasPrefix("choose: Overwrite") }.count == 1)
    }

    /// A rename of several items with a mask in a branch view leaves each in its own folder.
    @Test
    internal func aRenameOfSeveralItemsInABranchViewLeavesEachInItsFolder() throws {
        bench.left.show(try branch(of: "d"))
        bench.left.moveCursor(toName: "a.txt")
        commands.perform(.selectAll)
        interaction.formAnswers = [.values(["mask": .text("*.bak")])]
        commands.perform(.renameOnly)
        #expect(namesOnDisk(box.url("d")) == ["a.bak", "b.bak", "sub"] && namesOnDisk(box.url("d/sub")) == ["c.bak"])
    }

    // F002, F004, F011, F071
    /// A large selection put on the clipboard is remembered, and written out file by file only when the user asks
    /// for it.
    @Test
    internal func aLargeSelectionIsRememberedAndOnlyWrittenOutWhenAskedFor() throws {
        let count = ClipboardPlugin.eagerLimit + 5
        for index in 0..<count { try box.file("many/f\(index).txt", "\(index)") }
        bench.left.show(box.url("many"))
        bench.left.moveCursor(toName: "f0.txt")
        commands.perform(.selectAll)
        // "For This Program": one item on the pasteboard, the paths as a text made on demand.
        interaction.choiceAnswers = [0]
        commands.perform(.copyToClipboard)
        #expect(interaction.log.contains { $0.hasPrefix("choose: Copy \(count) files") })
        #expect(
            pasteboard.pasteboardItems?.count == 1
                && pasteboard.availableType(from: [.fileURL, .URL]) == nil
        )
        #expect(pasteboard.string(forType: .string)?.split(separator: "\n").count == count)
        // Paste here takes the files from memory.
        #expect(commands.isEnabled(.pasteFromClipboard))
        bench.right.focus()
        commands.perform(.pasteFromClipboard)
        #expect(namesOnDisk(box.url("t")).count == count && box.read("t/f\(count - 1).txt") == "\(count - 1)")
        // "Also for Other Programs": every file is on the pasteboard.
        bench.left.focus()
        interaction.choiceAnswers = [1]
        commands.perform(.copyToClipboard)
        #expect(urlsOnPasteboard().count == count)
        // Cancel leaves the clipboard as it is.
        pasteboard.clearContents()
        pasteboard.setString("kept", forType: .string)
        interaction.choiceAnswers = [2]
        commands.perform(.cutToClipboard)
        #expect(pasteboard.string(forType: .string) == "kept")
        // A small selection is written the usual way and nobody is asked.
        commands.perform(.unselectAll)
        bench.left.moveCursor(toName: "f1.txt")
        let questions = interaction.log.count
        commands.perform(.copyToClipboard)
        #expect(interaction.log.count == questions)
        #expect(urlsOnPasteboard().map(\.lastPathComponent) == ["f1.txt"])
    }

    /// Files another program puts on the pasteboard are pasted from the one list the system offers.
    @Test
    internal func filesAnotherProgramOffersAsOneListAreReadInOnePiece() {
        bench.right.focus()
        // Files written by somebody else: the system offers them as one list as well.
        pasteboard.clearContents()
        let written = [box.url("d/a.txt"), box.url("d/b.txt")]
            .map { url in
                // One item with the file's URL each, as the system writes a URL object.
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                return item
            }
        pasteboard.writeObjects(written)
        #expect((pasteboard.propertyList(forType: ClipboardPlugin.fileNamesType) as? [String])?.count == 2)
        #expect(commands.isEnabled(.pasteFromClipboard))
        commands.perform(.pasteFromClipboard)
        #expect(namesOnDisk(box.url("t")) == ["a.txt", "b.txt"])
        // The answer is remembered per state of the pasteboard, and follows it.
        pasteboard.clearContents()
        #expect(!commands.isEnabled(.pasteFromClipboard))
    }

    // F040
    /// A text on the clipboard is pasted as Clipboard.txt, and no draft is left beside it.
    @Test
    internal func aTextIsPastedAsAFileWithoutLeavingADraft() {
        pasteboard.clearContents()
        pasteboard.setString("some text", forType: .string)
        bench.right.focus()
        commands.perform(.pasteFromClipboard)
        #expect(namesOnDisk(box.url("t")) == ["Clipboard.txt"] && box.read("t/Clipboard.txt") == "some text")
    }

    // F055
    /// Line breaks and direction marks in names are written out as code points in questions and headings.
    @Test
    internal func namesThatCouldMisleadAreWrittenOutInQuestions() {
        #expect(DisplayName.escaped("plain name.txt") == "plain name.txt")
        #expect(DisplayName.escaped("a\nb\u{202E}txt.exe\u{200B}") == "a<U+000A>b<U+202E>txt.exe<U+200B>")
        let item = FileItem(url: box.url("d/x\ny"), name: "x\ny")
        #expect(OperationText.deleteQuestion([item], toTrash: false).contains("x<U+000A>y"))
        #expect(OperationText.heading("Copy", [item]) == "Copy \"x<U+000A>y\" to")
        #expect(PropertyText.shown("a\u{202E}b") == "a<U+202E>b")
    }
}

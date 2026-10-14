import AFMContracts
import AFMKernel
import AppKit
import FileOperationsPlugin
import LocalFileSystemPlugin
import SelectionPlugin
import TestSupport
import Testing

@testable import ClipboardPlugin

/// Names and details as text, and pasting a text or picture as a new file
/// (spec 07 › File clipboard and name lists).
@MainActor @Suite struct ClipboardMore {
    let memory = MemoryFileSystem()
    private let scratch = ScratchPasteboard()
    var pasteboard: NSPasteboard { scratch.pasteboard }
    let bench: TestBench
    let modified = Date(timeIntervalSince1970: 1_000_000)

    var commands: CommandRegistry { bench.commands }
    var left: FakePanel { bench.left }
    var text: String? { pasteboard.string(forType: .string) }

    init() {
        memory.addFile("/A/one.txt", "new")
        memory.addFile("/A/two.txt", "2", permissions: 0o600)
        memory.addFile("/A/docs/in.txt", "inside")
        memory.addDirectory("/B")
        bench = TestBench(
            plugins: [FileOperationsPlugin(), ClipboardPlugin(pasteboard: scratch.pasteboard), SelectionPlugin()],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
    }

    @Test func namesAreOneLineEachAndFoldersEndWithASlash() {
        commands.perform(.selectAll)
        commands.perform(ClipboardCommands.copyNames)
        #expect(text == "docs/\none.txt\ntwo.txt")
        commands.perform(.copyFullNames)
        #expect(text == "mem:/A/docs/\nmem:/A/one.txt\nmem:/A/two.txt")
        commands.perform(ClipboardCommands.copyNetNames)
        #expect(
            text
                == [
                    memory.url("/A/docs").absoluteString + "/", memory.url("/A/one.txt").absoluteString,
                    memory.url("/A/two.txt").absoluteString
                ]
                .joined(separator: "\n")
        )
        commands.perform(ClipboardCommands.copyPathOfFiles)
        #expect(text == "mem:/A\nmem:/A\nmem:/A")
        commands.perform(ClipboardCommands.copySourcePath)
        #expect(text == "mem:/A")
        commands.perform(ClipboardCommands.copyTargetPath)
        #expect(text == "mem:/B")
    }

    @Test func withoutASelectionTheCursorItemIsMeant() {
        left.moveCursor(toName: "two.txt")
        commands.perform(ClipboardCommands.copyNames)
        #expect(text == "two.txt")
        // On `[..]` there is no item; only the folder's own path can be copied.
        left.model.moveCursor(to: 0)
        #expect(!commands.isEnabled(ClipboardCommands.copyNames) && !commands.isEnabled(ClipboardCommands.copyDetails))
        commands.perform(.copyFullNames)
        #expect(text == "mem:/A")
    }

    @Test func detailsAreTabSeparatedColumns() {
        let date = Format.date(modified)
        commands.perform(.selectAll)
        commands.perform(ClipboardCommands.copyDetails)
        #expect(
            text == "docs/\t<DIR>\t\(Format.date(Date(timeIntervalSince1970: 0)))\trwxr-xr-x\n"
                + "one.txt\t3\t\(date)\trw-r--r--\ntwo.txt\t1\t\(date)\trw-------"
        )
        commands.perform(.unselectAll)
        left.moveCursor(toName: "one.txt")
        commands.perform(ClipboardCommands.copyDetailsWithPath)
        #expect(text == "mem:/A/one.txt\t3\t\(date)\trw-r--r--")
        commands.perform(ClipboardCommands.copyDetailsWithURL)
        #expect(text == "\(memory.url("/A/one.txt").absoluteString)\t3\t\(date)\trw-r--r--")
        commands.perform(ClipboardCommands.copyDetailsWithHeaders)
        #expect(text == "Name\tSize\tDate\tAttr\none.txt\t3\t\(date)\trw-r--r--")
        commands.perform(ClipboardCommands.copyDetailsWithHeadersAndPath)
        #expect(text?.hasSuffix("\nmem:/A/one.txt\t3\t\(date)\trw-r--r--") == true)
        commands.perform(ClipboardCommands.copyDetailsWithHeadersAndURL)
        #expect(text?.hasPrefix("Name\tSize\tDate\tAttr\nmem:") == true)
        // A bit mask picks columns: name and size.
        commands.perform(ClipboardCommands.copyDetailsWithHeaders, .index(3))
        #expect(text == "Name\tSize\none.txt\t3")
    }

    @Test func detailsIncludeThePluginColumnsThePanelShows() {
        bench.kernel.columns.register(ContentColumn(id: "shout", title: "Shout") { $0.name.uppercased() + "\t!" })
        bench.kernel.columns.register(ContentColumn(id: "unused", title: "Unused") { _ in "?" })
        left.extraColumns = ["shout"]
        commands.perform(.selectAll)
        commands.perform(ClipboardCommands.copyDetailsWithHeaders, .index(1 | 16))
        // Values are worked out in a job; a tab inside a value would break the table.
        #expect(text == "Name\tShout\ndocs/\tDOCS !\none.txt\tONE.TXT !\ntwo.txt\tTWO.TXT !")
        #expect(bench.jobService.titles == ["Reading details:"])
        // Brief view shows no columns.
        left.viewMode = .brief
        commands.perform(ClipboardCommands.copyDetailsWithHeaders)
        #expect(text?.hasPrefix("Name\tSize\tDate\tAttr\n") == true)
    }

    @Test func detailsCanBeSavedToAFile() {
        left.moveCursor(toName: "one.txt")
        commands.perform(ClipboardCommands.saveDetailsWithHeaders, .text("details.txt"))
        #expect(
            memory.contents("/A/details.txt")
                == "Name\tSize\tDate\tAttr\none.txt\t3\t\(Format.date(modified))\trw-r--r--"
        )
        #expect(left.model.cursorItem?.name == "details.txt")
        // The name is asked for; an existing file is replaced only after a question.
        left.moveCursor(toName: "two.txt")
        bench.ui.promptAnswers = [.accept]
        bench.ui.choiceAnswers = [1]
        commands.perform(ClipboardCommands.saveDetails)
        #expect(memory.contents("/A/details.txt")?.hasPrefix("Name") == true)
        bench.ui.promptAnswers = [.accept]
        bench.ui.choiceAnswers = [0]
        commands.perform(ClipboardCommands.saveDetails)
        #expect(memory.contents("/A/details.txt") == "two.txt\t1\t\(Format.date(modified))\trw-------")
        bench.ui.promptAnswers = [.cancel]
        commands.perform(ClipboardCommands.saveDetails)
        #expect(bench.jobService.titles.count == 3)
    }

    @Test func aTextOnTheClipboardIsPastedAsANewFile() {
        #expect(!commands.isEnabled(.pasteFromClipboard))
        pasteboard.clearContents()
        pasteboard.setString("hello\nworld", forType: .string)
        #expect(commands.isEnabled(.pasteFromClipboard))
        commands.perform(.pasteFromClipboard)
        #expect(memory.contents("/A/Clipboard.txt") == "hello\nworld" && left.model.cursorItem?.name == "Clipboard.txt")
        commands.perform(.pasteFromClipboard)
        #expect(
            memory.contents("/A/Clipboard (2).txt") == "hello\nworld"
                && left.model.cursorItem?.name == "Clipboard (2).txt"
        )
    }

    @Test func aPictureOnTheClipboardIsPastedAsPNG() throws {
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 2,
                pixelsHigh: 2,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        pasteboard.clearContents()
        pasteboard.setData(bitmap.tiffRepresentation, forType: .tiff)
        pasteboard.setString("picture", forType: .string)
        commands.perform(.pasteFromClipboard)
        #expect(left.model.cursorItem?.name == "Clipboard.png" && !memory.exists("/A/Clipboard.txt"))
        let reader = try memory.read(memory.url("/A/Clipboard.png"))
        #expect(try reader.read(upToCount: 4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func pastingContentsNeedsAWritableFolderAndCanBeSwitchedOff() {
        pasteboard.clearContents()
        pasteboard.setString("text", forType: .string)
        memory.capabilities = []
        #expect(!commands.isEnabled(.pasteFromClipboard))
        memory.capabilities = [.write]
        #expect(commands.isEnabled(.pasteFromClipboard))
        bench.kernel.settings.set(false, forKey: ClipboardPlugin.pastesContentsKey)
        #expect(!commands.isEnabled(.pasteFromClipboard))
    }

    @Test func filesOnTheClipboardWinOverText() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "1")
        try box.folder("B")
        left.show(box.url("A"))
        bench.right.show(box.url("B"))
        left.moveCursor(toName: "one.txt")
        commands.perform(.copyToClipboard)
        bench.right.focus()
        commands.perform(.pasteFromClipboard)
        #expect(box.read("B/one.txt") == "1" && !box.exists("B/Clipboard.txt"))
        // On the disk, pasted text is a file as well.
        pasteboard.clearContents()
        pasteboard.setString("note", forType: .string)
        commands.perform(.pasteFromClipboard)
        #expect(box.read("B/Clipboard.txt") == "note")
    }

    @Test func registration() {
        let inMenus =
            bench.kernel.menus.menus.flatMap(\.items).compactMap { $0 }
            + bench.kernel.menus.contextMenu(onItem: true).compactMap { $0 }
        #expect(inMenus.allSatisfy { commands[$0] != nil })
        #expect(bench.kernel.keyClashes.isEmpty)
        #expect(bench.kernel.preferences.pages.map(\.title).contains("Clipboard"))
        for id in [
            "cm_CopyNamesToClip", "cm_CopyFullNamesToClip", "cm_CopyNetNamesToClip", "cm_CopyPathOfFilesToClip",
            "cm_CopySrcPathToClip",
            "cm_CopyTrgPathToClip", "cm_CopyFileDetailsToClip", "cm_CopyFpFileDetailsToClip",
            "cm_CopyNetFileDetailsToClip",
            "cm_CopyHdrFileDetailsToClip", "cm_CopyHdrFpFileDetailsToClip", "cm_CopyHdrNetFileDetailsToClip",
            "cm_SaveDetailsToFile",
            "cm_SaveHdrDetailsToFile"
        ] {
            #expect(commands[CommandID(rawValue: id)] != nil, "\(id)")
        }
    }

    // MARK: Pure types

    @Test func freeNamesCountUp() {
        #expect(PastedContent.freeName(extension: "txt") { _ in false } == "Clipboard.txt")
        let taken: Set = ["Clipboard.png", "Clipboard (2).png"]
        #expect(PastedContent.freeName(extension: "png", isTaken: taken.contains) == "Clipboard (3).png")
    }

    @Test func aCalculatedFolderSizeReplacesDIR() {
        let list = NameList(displayPath: { $0.path })
        var folder = FileItem(url: URL(fileURLWithPath: "/x/docs"), name: "docs", isDirectory: true)
        #expect(list.details([folder], .fullPath, headers: false, mask: 3) == "/x/docs/\t<DIR>")
        folder.computedSize = 4_096
        #expect(list.details([folder], .name, headers: false, mask: 3) == "docs/\t4096")
        // A package is listed like a file and gets no slash.
        let app = FileItem(
            url: URL(fileURLWithPath: "/x/A.app"),
            name: "A.app",
            isDirectory: true,
            isPackage: true,
            size: 7
        )
        #expect(list.names([app], .name) == "A.app")
    }
}

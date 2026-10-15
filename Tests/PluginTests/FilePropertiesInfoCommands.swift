import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FilePropertiesPlugin

/// The commands for properties, occupied space, comments and links, driven through a kernel with fake panels.
@MainActor
@Suite
internal struct FilePropertiesInfoCommands {
    /// The kernel, its panels and the files.
    private let fixture: FilePropertiesBench

    /// The kernel's commands.
    private var commands: CommandRegistry { fixture.commands }
    /// The panel on `A`.
    private var left: FakePanel { fixture.left }
    /// The panel on `B`.
    private var right: FakePanel { fixture.right }
    /// The dialogs and messages, answered by script.
    private var dialogs: ScriptedInteraction { fixture.dialogs }

    /// A fresh sandbox and kernel for each test.
    internal init() throws {
        fixture = try FilePropertiesBench()
    }

    // MARK: Properties

    /// Properties of a file, a folder, the folder shown and a selection.
    @Test
    internal func propertiesOfFilesFoldersAndSelections() throws {
        try fixture.box.file("A/descript.ion", "one.txt the first\r\n")
        left.moveCursor(toName: "one.txt")
        dialogs.formAnswers = [.accept]
        commands.perform(.properties)
        #expect(dialogs.log.last == "form: Properties: one.txt")
        var rows = fixture.notes(dialogs.forms[0])
        #expect(
            rows.contains("Name: one.txt") && rows.contains("Size: 5 bytes")
                && rows.contains("Permissions: rw-r--r-- (644)")
        )
        #expect(rows.contains("Where: \(fixture.box.url("A").path)") && rows.contains("Comment: the first"))
        #expect(
            rows.contains { $0.hasPrefix("Owner: \(NSUserName()) (") }
                && rows.contains { $0.hasPrefix("Size on disk: ") }
        )
        for label in ["Kind", "Created", "Modified", "Accessed", "Group", "Volume"] {
            #expect(rows.contains { $0.hasPrefix(label + ": ") }, "\(label)")
        }
        #expect(fixture.plugin.finderInfoRequests.isEmpty)

        // A folder is counted with everything below it; the second button asks Finder.
        left.moveCursor(toName: "docs")
        dialogs.formAnswers = [.values([:], button: 1)]
        commands.perform(.properties)
        rows = fixture.notes(dialogs.forms[1])
        #expect(rows.contains("Size: 10 bytes") && rows.contains("Contains: 2 file(s), 1 folder(s)"))
        #expect(fixture.plugin.finderInfoRequests.map(\.path) == [fixture.box.url("A/docs").path])

        // On [..]: the folder the panel shows.
        left.model.moveCursor(to: 0)
        dialogs.formAnswers = [.accept]
        commands.perform(.properties)
        #expect(
            dialogs.log.last == "form: Properties: A"
                && fixture.notes(dialogs.forms[2]).contains("Contains: 5 file(s), 2 folder(s)")
        )

        // Several selected items are summed up.
        left.model.selectAll()
        dialogs.formAnswers = [.accept]
        commands.perform(.properties)
        rows = fixture.notes(dialogs.forms[3])
        #expect(dialogs.log.last == "form: Properties: 3 items" && rows.contains("Contains: 4 file(s), 2 folder(s)"))
        #expect(rows.contains("Items: 3: docs, one.txt, two.txt"))
    }

    /// Properties of an item outside the Mac's disks, and Finder's information of a local one.
    @Test
    internal func propertiesAndFinderInfoElsewhere() {
        left.show(fixture.memory.url("/M"))
        left.moveCursor(toName: "sub")
        dialogs.formAnswers = [.accept]
        commands.perform(.properties)
        let rows = fixture.notes(dialogs.forms[0])
        #expect(rows.contains("Size: 5 bytes") && rows.contains("Where: mem:/M") && rows.contains("Volume: Memory"))
        #expect(!rows.contains { $0.hasPrefix("Owner") || $0.hasPrefix("Size on disk") })
        // No Finder for what is not on the Mac's disks.
        #expect(!commands.isEnabled("afm_FinderInfo"))
        left.show(fixture.box.url("A"))
        left.moveCursor(toName: "two.txt")
        commands.perform("afm_FinderInfo")
        #expect(fixture.plugin.finderInfoRequests.map(\.path) == [fixture.box.url("A/two.txt").path])
    }

    // MARK: Occupied space

    /// Occupied space measures the operands and shows the folders' sizes in the list.
    @Test
    internal func occupiedSpaceMeasuresTheOperandsAndShowsFolderSizes() {
        left.moveCursor(toName: "docs")
        commands.perform(.occupiedSpace)
        #expect(
            dialogs.log.last == "inform: Total space occupied:"
                && fixture.bench.jobService.titles == ["Calculating occupied space:"]
        )
        #expect(left.model.items.first { $0.name == "docs" }?.computedSize == 10 && left.model.selection == ["docs"])
        // With a selection, the selection is measured, not the cursor item.
        left.model.clearSelection()
        left.model.toggleSelection(row: left.model.row(ofName: "one.txt") ?? -1)
        commands.perform(.occupiedSpace)
        #expect(left.model.selection == ["one.txt"])
        // The preference keeps measured folders unselected.
        fixture.bench.kernel.settings.set(false, forKey: "fileProperties.selectMeasuredFolders")
        left.show(fixture.memory.url("/M"))
        left.moveCursor(toName: "sub")
        commands.perform(.occupiedSpace)
        #expect(left.model.items.first { $0.name == "sub" }?.computedSize == 5 && left.model.selection.isEmpty)
        left.model.moveCursor(to: 0)
        #expect(!commands.isEnabled(.occupiedSpace))
    }

    /// Every folder of the list is measured at once.
    @Test
    internal func allFolderSizesAtOnce() throws {
        try fixture.box.file("A/more/x.bin", "1234567")
        left.reload()
        commands.perform("cm_CountDirContent")
        #expect(left.model.items.filter(\.isFolder).map(\.computedSize) == [10, 7] && left.model.selection.isEmpty)
        #expect(!dialogs.log.contains { $0.hasPrefix("inform") })
    }

    // MARK: Comments

    /// Comments are edited in the folder's hidden comment file.
    @Test
    internal func editsCommentsInTheFoldersCommentFile() {
        fixture.bench.kernel.columns["comment"].map { left.extraColumns = [$0.id] }
        left.moveCursor(toName: "one.txt")
        dialogs.formAnswers = [.values(["comment": .text("first line\nsecond line")])]
        commands.perform("cm_EditComment")
        #expect(dialogs.log.contains("form: File comment"))
        let bytes = FileManager.default.contents(atPath: fixture.box.url("A/descript.ion").path)
        #expect(bytes == Data("one.txt first line\\nsecond line".utf8) + Data([0x04, 0xC2, 0x0D, 0x0A]))
        // The new comment file is hidden, so the list stays as it was.
        #expect(
            fixture.flags("A/descript.ion") & UInt32(UF_HIDDEN) != 0 && left.names == ["docs", "one.txt", "two.txt"]
        )
        let column = fixture.bench.kernel.columns["comment"]
        #expect(left.model.cursorItem.map { column?.value($0) } == "first line second line")

        // The dialog shows the comment that is there; an unchanged or cancelled dialog writes nothing.
        dialogs.formAnswers = [.accept, .cancel, .values(["comment": .text("")])]
        commands.perform("cm_EditComment")
        commands.perform("cm_EditComment")
        #expect(
            dialogs.forms[1].first?.initialValue == .text("first line\nsecond line")
                && fixture.bench.jobService.titles.filter { $0 == "Saving comment:" }.count == 1
        )
        // An empty comment removes the entry, and the file with its last entry.
        commands.perform("cm_EditComment")
        #expect(
            !fixture.box.exists("A/descript.ion")
                && left.model.cursorItem.flatMap { column?.value($0) }?.isEmpty == true
        )
    }

    /// Comments work on any writable file system, and for the folder the panel shows.
    @Test
    internal func commentsWorkOnAnyWritableFileSystemAndForTheFolderItself() {
        left.show(fixture.memory.url("/M/sub"))
        // On [..] the comment belongs to the folder the panel shows and lives one level up.
        left.model.moveCursor(to: 0)
        dialogs.formAnswers = [.values(["comment": .text("a folder")])]
        commands.perform("cm_EditComment")
        #expect(fixture.memory.contents("/M/descript.ion") == "sub a folder\r\n")
        left.moveCursor(toName: "b.txt")
        dialogs.formAnswers = [
            .values(["comment": .text(String(repeating: "x", count: 5_000))]), .values(["comment": .text("größer")])
        ]
        commands.perform("cm_EditComment")
        #expect(
            dialogs.log.contains("inform: The comment is too long!")
                && dialogs.log.filter { $0 == "form: File comment" }.count == 3
        )
        #expect(
            fixture.memory.allPaths.filter { $0.contains("descript") } == ["/M/descript.ion", "/M/sub/descript.ion"]
        )
        fixture.memory.capabilities = []
        #expect(!commands.isEnabled("cm_EditComment"))
    }

    // MARK: Links

    /// Symbolic links, aliases and hard links are created, never over an existing name.
    @Test
    internal func createsSymbolicLinksAliasesAndHardLinks() throws {
        left.moveCursor(toName: "one.txt")
        dialogs.formAnswers = [.accept]
        commands.perform("cm_CreateShortcut")
        #expect(
            dialogs.log.last == "form: Create link"
                && dialogs.forms[0].first?.initialValue == .text(fixture.box.url("B").path + "/one.txt")
        )
        #expect(LocalInfo.linkTarget(fixture.box.url("B/one.txt")) == fixture.box.url("A/one.txt").path)
        #expect(right.names == ["one.txt", "other.txt"] && right.model.cursorItem?.name == "one.txt")

        // Another name, relative, and the other kinds of link.
        dialogs.formAnswers = [
            .values(["target": .text(fixture.box.url("B").path + "/rel.txt"), "relative": .flag(true)]),
            .values(["target": .text(fixture.box.url("B").path + "/hard.txt"), "kind": .index(LinkKind.hard.rawValue)]),
            .values(["target": .text(fixture.box.url("B").path + "/alias"), "kind": .index(LinkKind.alias.rawValue)])
        ]
        for _ in 0..<3 { commands.perform("cm_CreateShortcut") }
        #expect(
            LocalInfo.linkTarget(fixture.box.url("B/rel.txt")) == "../A/one.txt"
                && fixture.box.read("B/rel.txt") == "12345"
        )
        #expect(
            LocalInfo.details(fixture.box.url("A/one.txt"))?.linkCount == 2 && fixture.box.read("B/hard.txt") == "12345"
        )
        #expect(
            LocalInfo.resolvedLinkTarget(fixture.box.url("B/alias"))?.resolvingSymlinksInPath().path
                == fixture.box.url("A/one.txt").path
        )

        // An existing name is never replaced; several operands go into the folder under their names.
        dialogs.formAnswers = [.accept]
        commands.perform("cm_CreateShortcut")
        #expect(dialogs.log.last == "inform: 1 link(s) could not be created!")
        left.model.selectAll()
        dialogs.formAnswers = [.values(["target": .text(fixture.box.url("B/links").path)])]
        try fixture.box.folder("B/links")
        commands.perform("cm_CreateShortcut")
        #expect(namesOnDisk(fixture.box.url("B/links")) == ["docs", "one.txt", "two.txt"])
        #expect(dialogs.forms.last?.first?.initialValue == .text(fixture.box.url("B").path + "/"))
        // Only the Mac's own file system has links.
        left.show(fixture.memory.url("/M"))
        left.moveCursor(toName: "a.txt")
        #expect(!commands.isEnabled("cm_CreateShortcut") && !commands.isEnabled("afm_ShowLinkTarget"))
    }

    /// The panel goes to a link's target and puts the cursor on it.
    @Test
    internal func goesToTheTargetOfALink() throws {
        try FileManager.default.createSymbolicLink(
            atPath: fixture.box.url("A/to-more").path,
            withDestinationPath: "docs/deep/more.txt"
        )
        left.reload()
        left.moveCursor(toName: "to-more")
        commands.perform("afm_ShowLinkTarget")
        #expect(
            left.model.directory.path == fixture.box.url("A/docs/deep").path
                && left.model.cursorItem?.name == "more.txt"
        )
        commands.perform("afm_ShowLinkTarget")
        #expect(dialogs.log.last == "inform: more.txt is not a link.")
    }
}

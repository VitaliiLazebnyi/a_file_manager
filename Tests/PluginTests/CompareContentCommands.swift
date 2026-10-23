import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import CompareContentPlugin

/// Compare by content driven through its command and its session, with fake panels, a
/// scripted user and jobs that run at once: which files, and the comparison.
///
/// No window is involved.
@MainActor
@Suite
internal struct CompareContentCommands {
    /// The folders, the plugin and the bench.
    private let fixture = CompareContentFixture()

    /// The two folders.
    private var memory: MemoryFileSystem { fixture.memory }
    /// The settings of the bench.
    private var settings: MemorySettings { fixture.settings }
    /// The kernel with the plugin.
    private var bench: TestBench { fixture.bench }
    /// The scripted answers of the user, and what was asked.
    private var interaction: ScriptedInteraction { fixture.interaction }
    /// The session of the last comparison.
    private var session: CompareSession { fixture.session }

    /// The command is registered with its menu items, its toolbar button and its preference page.
    @Test
    internal func commandIsRegisteredWithMenusButtonAndPreferences() {
        #expect(bench.commands[.compareByContent]?.title == "Compare By Content…")
        #expect(bench.kernel.menus.menus.first { $0.title == "Files" }?.items.contains(.compareByContent) == true)
        #expect(bench.kernel.menus.contextMenu(onItem: true).contains(.compareByContent))
        #expect(!bench.kernel.menus.contextMenu(onItem: false).contains(.compareByContent))
        #expect(bench.kernel.toolbar.defaultLayout.contains { $0?.command == .compareByContent })
        #expect(bench.kernel.preferences.pages.contains { $0.title == "Compare by content" })
        #expect(bench.kernel.keyClashes.isEmpty)
    }

    /// Two selected files of the source panel are the two compared.
    @Test
    internal func twoSelectedFilesOfTheSourcePanel() {
        bench.left.model.select(mask: "other.txt third.txt notes.txt folder")
        // The first two in list order; folders do not count.
        #expect(fixture.operands() == ["/A/notes.txt", "/A/other.txt"])
    }

    /// One selected file is compared with the target's selected file, else with the one of the same name.
    @Test
    internal func oneSelectedFileWithTheTargetsSelectionOrTheSameName() {
        bench.left.model.select(mask: "notes.txt")
        bench.right.model.select(mask: "zebra.txt twin.txt")
        #expect(fixture.operands() == ["/A/notes.txt", "/B/twin.txt"])
        bench.right.model.clearSelection()
        #expect(fixture.operands() == ["/A/notes.txt", "/B/notes.txt"])
        bench.left.model.clearSelection()
        bench.left.model.select(mask: "other.txt")
        // Nothing of that name on the other side: the user has to choose.
        #expect(fixture.operands() == ["/A/other.txt", nil])
        #expect(session.phase == .empty && session.status == "Choose two files and press Compare")
    }

    /// Without a selection, the file under the cursor is compared with the one of the same name in the other panel.
    @Test
    internal func theCursorFileWithTheSameNameInTheOtherPanel() {
        bench.left.moveCursor(toName: "notes.txt")
        // The target panel's cursor is never used.
        bench.right.moveCursor(toName: "zebra.txt")
        #expect(fixture.operands() == ["/A/notes.txt", "/B/notes.txt"])
        #expect(session.blocks.count == 2 && session.status.hasPrefix("2 differences"))

        bench.left.moveCursor(toName: "third.txt")
        #expect(fixture.operands() == ["/A/third.txt", nil])
        bench.left.moveCursor(toName: "folder")
        #expect(fixture.operands() == [nil, nil])
        // From the right panel, its file is the first one.
        bench.right.focus()
        bench.right.moveCursor(toName: "notes.txt")
        #expect(fixture.operands() == ["/B/notes.txt", "/A/notes.txt"])
        // Both panels in one folder: a file is not compared with itself.
        bench.right.show(memory.url("/A"))
        bench.right.moveCursor(toName: "notes.txt")
        #expect(fixture.operands() == ["/A/notes.txt", nil])
    }

    /// Other plugins name the two files themselves, as text or a location.
    @Test
    internal func otherPluginsNameTheFilesThemselves() {
        #expect(fixture.operands(.text("mem:///A/other.txt\nmem:///B/zebra.txt")) == ["/A/other.txt", "/B/zebra.txt"])
        #expect(session.blocks.count == 1)
        #expect(fixture.operands(.text("mem:/A/third.txt\n")) == ["/A/third.txt", nil])
        #expect(fixture.operands(.text("\nmem:/B/zebra.txt")) == [nil, "/B/zebra.txt"])
        #expect(fixture.operands(.text("third.txt\n/B/zebra.txt")) == ["/A/third.txt", "/B/zebra.txt"])
        #expect(fixture.operands(.location(memory.url("/B/zebra.txt"))) == ["/B/zebra.txt", nil])
    }

    /// Identical files only get the message, and so does a file that is missing.
    @Test
    internal func identicalFilesOnlyGetTheMessage() {
        bench.left.moveCursor(toName: "twin.txt")
        bench.commands.perform(.compareByContent)
        #expect(interaction.log == ["inform: Compare contents"])
        #expect(session.isIdentical && session.status.hasPrefix("The two files have the same content!"))

        _ = fixture.operands(.text("mem:/A/twin.txt\nmem:/A/gone.txt"))
        #expect(
            interaction.log.count == 2 && session.status == "mem:/A/gone.txt is not a file." && session.rowCount == 0
        )
    }

    /// The rows, their numbers and highlights, the differences and the search.
    @Test
    internal func rowsNumbersAndHighlights() {
        bench.left.moveCursor(toName: "notes.txt")
        bench.commands.perform(.compareByContent)
        #expect(fixture.rows() == ["one|one", "two|2", "three|three", "four|four", "~|five"])
        #expect((0..<5).map { session.kind(ofRow: $0) } == [.equal, .changed, .equal, .equal, .added])
        #expect(
            session.label(.left, row: 1) == "2" && session.label(.left, row: 4).isEmpty
                && session.label(.right, row: 4) == "5"
        )
        #expect(session.highlights(.left, row: 1) == [0..<3] && session.highlights(.right, row: 1) == [0..<1])
        #expect(session.highlights(.left, row: 0).isEmpty && session.highlights(.right, row: 4).isEmpty)
        #expect(session.width == 5 && !session.isBinary)
        #expect(
            session.block(containing: 1) == 1..<2 && session.block(containing: 2) == nil
                && session.block(containing: 4) == 4..<5
        )
        #expect(session.status == "2 differences    UTF-8 <-> UTF-8")

        // Next and previous difference, and searching in both files.
        #expect(session.difference(from: 0, forward: true) == 1 && session.difference(from: 1, forward: true) == 4)
        #expect(session.difference(from: 4, forward: true) == nil && session.difference(from: 4, forward: false) == 1)
        #expect(session.difference(from: 1, forward: false) == nil)
        #expect(session.find("FIVE", from: 0, forward: true) == 4 && session.find("two", from: 4, forward: true) == 1)
        #expect(
            session.find("three", from: 0, forward: false) == 2
                && session.find("absent", from: 0, forward: true) == nil
        )
    }

    /// The options are applied at once and remembered for the next window.
    @Test
    internal func optionsAreAppliedAndRemembered() {
        memory.addFile("/A/case.txt", "Hello  World\r\nsame\n")
        memory.addFile("/B/case.txt", "hello world\nsame\n")
        fixture.compare("case.txt")
        // Equal for the default options, though the bytes differ: no message, no differences.
        #expect(session.blocks.isEmpty && !session.isIdentical && interaction.log.isEmpty)
        #expect(session.status.hasPrefix("No differences with the current options"))
        let first = session
        first.options.ignoreCase = false
        first.optionsChanged()
        #expect(first.blocks == [0..<1])
        first.options = DiffOptions(ignoreCase: true, ignoreRepeatedSpaces: true, ignoreLineEndings: false)
        first.optionsChanged()
        #expect(first.blocks == [0..<1])
        first.options.ignoreRepeatedSpaces = false
        first.optionsChanged()

        // The next window starts with the options last used.
        bench.commands.perform(.compareByContent)
        #expect(
            session !== first
                && session.options
                    == DiffOptions(ignoreCase: true, ignoreRepeatedSpaces: false, ignoreLineEndings: false)
        )
        #expect(settings.flag("compareContent.ignoreLineEndings", default: true) == false)
    }

    /// Binary files are compared in hex, and so is a text file with "Binary".
    @Test
    internal func binaryFilesAreComparedInHex() {
        memory.addFile("/A/data.bin", "AB\u{0}DEFGHIJKLMNOPQRS")
        memory.addFile("/B/data.bin", "AB\u{0}DEFGHIJKLMNOPQxS!")
        fixture.compare("data.bin")
        #expect(session.isBinary && session.rowCount == 2 && session.blocks == [1..<2])
        #expect(session.status == "1 difference, 2 bytes differ    binary")
        #expect(
            session.label(.left, row: 1) == "00000010"
                && session.text(.left, row: 1) == "51 52 53" + String(repeating: " ", count: 41) + "QRS"
        )
        #expect(
            session.highlights(.right, row: 1) == [3..<5, 50..<51, 9..<11, 52..<53]
                && session.highlights(.left, row: 0).isEmpty
        )
        session.bytesPerLine = 8
        session.optionsChanged()
        #expect(session.rowCount == 3 && session.blocks == [2..<3] && session.label(.right, row: 2) == "00000010")
        // Edit mode is for texts.
        session.setEditing(true)
        #expect(!session.isEditing)

        // "Binary" shows a text file in hex as well.
        bench.left.moveCursor(toName: "notes.txt")
        bench.commands.perform(.compareByContent)
        session.forceBinary = true
        session.compare()
        #expect(session.isBinary && session.label(.left, row: 0) == "00000000")
    }

    /// Resynchronizing pairs two lines, forgetting it undoes that, and Swap exchanges the sides.
    @Test
    internal func resyncAndSwap() throws {
        memory.addFile("/A/r.txt", "start\nrepeat\nrepeat\nleft only\nend\n")
        memory.addFile("/B/r.txt", "start\nrepeat\nright only\nrepeat\nend\n")
        fixture.compare("r.txt")
        let before = fixture.rows()
        let leftRow = try #require((0..<session.rowCount).last { row in session.text(.left, row: row) == "repeat" })
        let rightRow = try #require(
            (0..<session.rowCount).first { row in session.text(.right, row: row) == "repeat" }
        )
        session.resync(leftRow: leftRow, rightRow: rightRow)
        #expect(
            fixture.rows() != before && fixture.rows().contains("repeat|repeat")
                && session.status.hasSuffix("[resynchronized]")
        )
        #expect(fixture.rows().filter { $0.hasPrefix("repeat|") }.count == 2 && session.anchors.count == 1)
        session.clearResync()
        #expect(fixture.rows() == before)

        session.swap()
        #expect(
            session.leftURL?.path == "/B/r.txt" && fixture.rows().contains("right only|left only")
                || fixture.rows().contains("right only|~")
        )
        #expect(
            fixture.rows().compactMap { $0.split(separator: "|").first }.filter { $0 != "~" } == [
                "start", "repeat", "right only", "repeat", "end"
            ]
        )
    }
}

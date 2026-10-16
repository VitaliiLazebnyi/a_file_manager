import AFMContracts
import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import CompareContentPlugin

/// Compare by content driven through its command and its session, with fake panels, a
/// scripted user and jobs that run at once. No window is involved.
@MainActor @Suite struct CompareContentCommands {
    let memory = MemoryFileSystem()
    let plugin = CompareContentPlugin(opensWindows: false)
    let settings = MemorySettings()
    let bench: TestBench

    var ui: ScriptedInteraction { bench.interaction }
    var session: CompareSession { plugin.sessions[0] }

    init() {
        memory.addFile("/A/notes.txt", "one\ntwo\nthree\nfour\n")
        memory.addFile("/B/notes.txt", "one\n2\nthree\nfour\nfive\n")
        memory.addFile("/A/other.txt", "alpha\n")
        memory.addFile("/A/third.txt", "beta\n")
        memory.addFile("/A/twin.txt", "the same\n")
        memory.addFile("/B/twin.txt", "the same\n")
        memory.addFile("/B/zebra.txt", "gamma\n")
        memory.addFile("/A/folder/inside.txt")
        memory.addFile("/B/folder/inside.txt")
        bench = TestBench(
            plugins: [plugin],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B"),
            settings: settings
        )
    }

    /// Runs the command and returns the names of the two files it took.
    func operands(_ argument: CommandArgument = .nothing) -> [String?] {
        bench.commands.perform(.compareByContent, argument)
        return [session.leftURL?.path, session.rightURL?.path]
    }

    /// Compares the file of that name in the left panel with its partner, after re-reading
    /// the panels for files a test has just made.
    func compare(_ name: String) {
        bench.left.reload()
        bench.right.reload()
        bench.left.moveCursor(toName: name)
        bench.commands.perform(.compareByContent)
    }

    /// The left and right texts of the rows, `|` between the sides.
    func rows() -> [String] {
        (0..<session.rowCount).map { "\(session.text(.left, row: $0) ?? "~")|\(session.text(.right, row: $0) ?? "~")" }
    }

    @Test func commandIsRegisteredWithMenusButtonAndPreferences() {
        #expect(bench.commands[.compareByContent]?.title == "Compare By Content…")
        #expect(bench.kernel.menus.menus.first { $0.title == "Files" }?.items.contains(.compareByContent) == true)
        #expect(bench.kernel.menus.contextMenu(onItem: true).contains(.compareByContent))
        #expect(!bench.kernel.menus.contextMenu(onItem: false).contains(.compareByContent))
        #expect(bench.kernel.toolbar.defaultLayout.contains { $0?.command == .compareByContent })
        #expect(bench.kernel.preferences.pages.contains { $0.title == "Compare by content" })
        #expect(bench.kernel.keyClashes.isEmpty)
    }

    // MARK: Which files (spec 09 › Opening and choosing the files)

    @Test func twoSelectedFilesOfTheSourcePanel() {
        bench.left.model.select(mask: "other.txt third.txt notes.txt folder")
        // The first two in list order; folders do not count.
        #expect(operands() == ["/A/notes.txt", "/A/other.txt"])
    }

    @Test func oneSelectedFileWithTheTargetsSelectionOrTheSameName() {
        bench.left.model.select(mask: "notes.txt")
        bench.right.model.select(mask: "zebra.txt twin.txt")
        #expect(operands() == ["/A/notes.txt", "/B/twin.txt"])
        bench.right.model.clearSelection()
        #expect(operands() == ["/A/notes.txt", "/B/notes.txt"])
        bench.left.model.clearSelection()
        bench.left.model.select(mask: "other.txt")
        // Nothing of that name on the other side: the user has to choose.
        #expect(operands() == ["/A/other.txt", nil])
        #expect(session.phase == .empty && session.status == "Choose two files and press Compare")
    }

    @Test func theCursorFileWithTheSameNameInTheOtherPanel() {
        bench.left.moveCursor(toName: "notes.txt")
        // The target panel's cursor is never used.
        bench.right.moveCursor(toName: "zebra.txt")
        #expect(operands() == ["/A/notes.txt", "/B/notes.txt"])
        #expect(session.blocks.count == 2 && session.status.hasPrefix("2 differences"))

        bench.left.moveCursor(toName: "third.txt")
        #expect(operands() == ["/A/third.txt", nil])
        bench.left.moveCursor(toName: "folder")
        #expect(operands() == [nil, nil])
        // From the right panel, its file is the first one.
        bench.right.focus()
        bench.right.moveCursor(toName: "notes.txt")
        #expect(operands() == ["/B/notes.txt", "/A/notes.txt"])
        // Both panels in one folder: a file is not compared with itself.
        bench.right.show(memory.url("/A"))
        bench.right.moveCursor(toName: "notes.txt")
        #expect(operands() == ["/A/notes.txt", nil])
    }

    @Test func otherPluginsNameTheFilesThemselves() {
        #expect(operands(.text("mem:///A/other.txt\nmem:///B/zebra.txt")) == ["/A/other.txt", "/B/zebra.txt"])
        #expect(session.blocks.count == 1)
        #expect(operands(.text("mem:/A/third.txt\n")) == ["/A/third.txt", nil])
        #expect(operands(.text("\nmem:/B/zebra.txt")) == [nil, "/B/zebra.txt"])
        #expect(operands(.text("third.txt\n/B/zebra.txt")) == ["/A/third.txt", "/B/zebra.txt"])
        #expect(operands(.location(memory.url("/B/zebra.txt"))) == ["/B/zebra.txt", nil])
    }

    @Test func identicalFilesOnlyGetTheMessage() {
        bench.left.moveCursor(toName: "twin.txt")
        bench.commands.perform(.compareByContent)
        #expect(ui.log == ["inform: Compare contents"])
        #expect(session.isIdentical && session.status.hasPrefix("The two files have the same content!"))

        _ = operands(.text("mem:/A/twin.txt\nmem:/A/gone.txt"))
        #expect(ui.log.count == 2 && session.status == "mem:/A/gone.txt is not a file." && session.rowCount == 0)
    }

    // MARK: The comparison

    @Test func rowsNumbersAndHighlights() {
        bench.left.moveCursor(toName: "notes.txt")
        bench.commands.perform(.compareByContent)
        #expect(rows() == ["one|one", "two|2", "three|three", "four|four", "~|five"])
        #expect((0..<5).map { session.kind(ofRow: $0) } == [.equal, .changed, .equal, .equal, .added])
        #expect(
            session.label(.left, row: 1) == "2" && session.label(.left, row: 4) == ""
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

    @Test func optionsAreAppliedAndRemembered() {
        memory.addFile("/A/case.txt", "Hello  World\r\nsame\n")
        memory.addFile("/B/case.txt", "hello world\nsame\n")
        compare("case.txt")
        // Equal for the default options, though the bytes differ: no message, no differences.
        #expect(session.blocks.isEmpty && !session.isIdentical && ui.log.isEmpty)
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

    @Test func binaryFilesAreComparedInHex() {
        memory.addFile("/A/data.bin", "AB\u{0}DEFGHIJKLMNOPQRS")
        memory.addFile("/B/data.bin", "AB\u{0}DEFGHIJKLMNOPQxS!")
        compare("data.bin")
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

    @Test func resyncAndSwap() {
        memory.addFile("/A/r.txt", "start\nrepeat\nrepeat\nleft only\nend\n")
        memory.addFile("/B/r.txt", "start\nrepeat\nright only\nrepeat\nend\n")
        compare("r.txt")
        let before = rows()
        let leftRow = (0..<session.rowCount).last { session.text(.left, row: $0) == "repeat" }!
        let rightRow = (0..<session.rowCount).first { session.text(.right, row: $0) == "repeat" }!
        session.resync(leftRow: leftRow, rightRow: rightRow)
        #expect(rows() != before && rows().contains("repeat|repeat") && session.status.hasSuffix("[resynchronized]"))
        #expect(rows().filter { $0.hasPrefix("repeat|") }.count == 2 && session.anchors.count == 1)
        session.clearResync()
        #expect(rows() == before)

        session.swap()
        #expect(
            session.leftURL?.path == "/B/r.txt" && rows().contains("right only|left only")
                || rows().contains("right only|~")
        )
        #expect(
            rows().compactMap { $0.split(separator: "|").first }.filter { $0 != "~" } == [
                "start", "repeat", "right only", "repeat", "end"
            ]
        )
    }

    // MARK: Editing and saving

    @Test func differencesAreCopiedAcrossUndoneAndSaved() {
        bench.left.moveCursor(toName: "notes.txt")
        bench.commands.perform(.compareByContent)
        // Nothing can be changed outside edit mode.
        session.copy(rows: 1..<2, to: .right)
        #expect(rows()[1] == "two|2" && !session.hasUnsavedChanges)

        session.setEditing(true)
        session.copy(rows: 1..<2, to: .right)
        #expect(rows() == ["one|one", "two|two", "three|three", "four|four", "~|five"])
        #expect(
            session.modified.right && !session.modified.left && session.label(.right, row: 1) == "0"
                && session.status.contains("[modified]")
        )
        // The line the left does not have is taken over from the right…
        session.copy(rows: 4..<5, to: .left)
        #expect(rows().last == "five|five" && session.blocks.isEmpty && session.modified.left)
        session.undo()
        #expect(rows().last == "~|five" && !session.modified.left && session.modified.right)
        // …or removed on the right by copying the left's nothing.
        session.copy(rows: 4..<5, to: .right)
        #expect(rows() == ["one|one", "two|two", "three|three", "four|four"] && session.canUndo)
        session.undo()
        session.undo()
        #expect(rows()[1] == "two|2" && !session.hasUnsavedChanges && !session.canUndo)

        session.copy(rows: 1..<2, to: .left)
        session.setText("FOUR and more", .left, row: 3)
        session.setText("three", .left, row: 2)  // unchanged text is no edit
        #expect(rows() == ["one|one", "2|2", "three|three", "FOUR and more|four", "~|five"])
        session.save()
        #expect(bench.jobService.titles == ["Save"])
        #expect(
            memory.contents("/A/notes.txt") == "one\n2\nthree\nFOUR and more\n"
                && memory.contents("/B/notes.txt") == "one\n2\nthree\nfour\nfive\n"
        )
        #expect(!session.hasUnsavedChanges && !memory.allPaths.contains { $0.contains("afm-save") })
        #expect(bench.left.model.items.first { $0.name == "notes.txt" }?.size == 26)
    }

    @Test func wholeBlocksAndInsertionsGoToTheRightPlace() {
        memory.addFile("/A/block.txt", "head\na1\na2\na3\ntail")
        memory.addFile("/B/block.txt", "head\r\nb1\r\ntail\r\nextra\r\n")
        compare("block.txt")
        #expect(rows() == ["head|head", "a1|b1", "a2|~", "a3|~", "tail|tail", "~|extra"])
        session.setEditing(true)
        session.copy(rows: session.blocks[0], to: .right)
        #expect(rows() == ["head|head", "a1|a1", "a2|a2", "a3|a3", "tail|tail", "~|extra"])
        session.copy(rows: 5..<6, to: .left)
        session.save()
        // Copied lines take the line break the target file mostly uses.
        #expect(memory.contents("/B/block.txt") == "head\r\na1\r\na2\r\na3\r\ntail\r\nextra\r\n")
        #expect(memory.contents("/A/block.txt") == "head\na1\na2\na3\ntail\nextra\n")
    }

    @Test func aFailedSaveIsReportedAndTheChangesStay() {
        bench.left.moveCursor(toName: "notes.txt")
        bench.commands.perform(.compareByContent)
        session.setEditing(true)
        session.copy(rows: 1..<2, to: .right)
        memory.removeTree("/B")
        var saved: Bool?
        session.save { saved = $0 }
        #expect(
            saved == false && session.hasUnsavedChanges && ui.log.last == "inform: mem:/B/notes.txt could not be saved."
        )
    }

    @Test func encodingsSurviveEditing() throws {
        let box = try Sandbox()
        try (Data([0xFF, 0xFE]) + "erste\r\nzweite\r\n".data(using: .utf16LittleEndian)!)
            .write(
                to: box.url("utf16.txt")
            )
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0A, 0x7A, 0x77, 0x65, 0x69, 0x74, 0x65, 0x0A])
            .write(
                to: box.url("latin.txt")
            )
        _ = operands(.text(box.url("utf16.txt").absoluteString + "\n" + box.url("latin.txt").absoluteString))
        #expect(session.status == "1 difference    UTF-16 LE <-> Latin-1" && rows() == ["erste|café", "zweite|zweite"])
        session.setEditing(true)
        session.copy(rows: 0..<1, to: .left)
        session.setText("dritte", .right, row: 1)
        session.save()
        #expect(
            try Data(contentsOf: box.url("utf16.txt")) == Data([0xFF, 0xFE]) + "café\r\nzweite\r\n"
                .data(
                    using: .utf16LittleEndian
                )!
        )
        #expect(
            try Data(contentsOf: box.url("latin.txt"))
                == Data([0x63, 0x61, 0x66, 0xE9, 0x0A, 0x64, 0x72, 0x69, 0x74, 0x74, 0x65, 0x0A])
        )
    }
}

/// The window itself: opened when the background comparison has found differences, and drawn.
@MainActor @Suite struct CompareContentWindow {
    func spin(until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(20)
        while !done(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    @Test func windowOpensForDifferentFilesOnly() async {
        let memory = MemoryFileSystem()
        memory.addFile("/A/a.txt", (0..<500).map { "line \($0)" }.joined(separator: "\n"))
        memory.addFile(
            "/B/a.txt",
            (0..<500).map { $0 % 50 == 7 ? "changed \($0)" : "line \($0)" }.joined(separator: "\n")
        )
        memory.addFile("/A/same.txt", "same")
        memory.addFile("/B/same.txt", "same")
        memory.addFile("/A/data.bin", "\u{0}\u{1}binary")
        memory.addFile("/B/data.bin", "\u{0}\u{1}BINARY and more")
        // The windows are made but never put on the desktop: `present` only counts.
        let presenter = StabilityPresenter()
        let windowWatch = StabilityWindows { $0.title.hasPrefix("Compare contents") }
        var effects = CompareWindowEffects.system
        effects.present = { [presenter] in presenter.present($0) }
        effects.beep = {}
        let plugin = CompareContentPlugin(opensWindows: true, effects: effects)
        defer {
            plugin.stop()
            presenter.closeAll()
            #expect(windowWatch.shown.isEmpty && windowWatch.open.isEmpty)
            windowWatch.closeAll()
        }
        let bench = TestBench(
            plugins: [plugin],
            fileSystems: [memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
        func windows() -> [NSWindow] {
            plugin.windows.compactMap(\.window)
        }

        bench.left.moveCursor(toName: "same.txt")
        bench.commands.perform(.compareByContent)
        await spin { plugin.sessions.isEmpty }
        #expect(windows().isEmpty && bench.interaction.log == ["inform: Compare contents"])

        bench.left.moveCursor(toName: "a.txt")
        bench.commands.perform(.compareByContent)
        await spin { !windows().isEmpty && plugin.sessions.first?.phase == .ready }
        #expect(windows().count == 1 && plugin.sessions.count == 1 && plugin.sessions[0].blocks.count == 10)
        windows()[0].contentView?.layoutSubtreeIfNeeded()
        windows()[0].displayIfNeeded()
        plugin.sessions[0].setEditing(true)
        plugin.sessions[0].copy(rows: 7..<8, to: .right)
        windows()[0].displayIfNeeded()
        #expect(plugin.sessions[0].blocks.count == 9)
        plugin.sessions[0].undo()

        // Several windows may be open at once.
        bench.left.moveCursor(toName: "data.bin")
        bench.commands.perform(.compareByContent)
        await spin { windows().count == 2 && plugin.sessions.last?.phase == .ready }
        #expect(windows().count == 2 && plugin.sessions.last?.isBinary == true && presenter.requests == 3)
        windows().forEach { $0.displayIfNeeded() }
        plugin.stop()
        #expect(windows().isEmpty && plugin.sessions.isEmpty)
    }
}

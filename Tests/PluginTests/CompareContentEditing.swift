import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import CompareContentPlugin

/// Compare by content in edit mode, driven through its session: copying, undoing and saving.
///
/// No window is involved.
@MainActor
@Suite
internal struct CompareContentEditing {
    /// The folders, the plugin and the bench.
    private let fixture = CompareContentFixture()

    /// The two folders.
    private var memory: MemoryFileSystem { fixture.memory }
    /// The plugin.
    private var plugin: CompareContentPlugin { fixture.plugin }
    /// The settings of the bench.
    private var settings: MemorySettings { fixture.settings }
    /// The kernel with the plugin.
    private var bench: TestBench { fixture.bench }
    /// The scripted answers of the user, and what was asked.
    private var interaction: ScriptedInteraction { fixture.interaction }
    /// The session of the last comparison.
    private var session: CompareSession { fixture.session }

    /// Differences are copied across in edit mode, undone, and saved through a job.
    @Test
    internal func differencesAreCopiedAcrossUndoneAndSaved() {
        bench.left.moveCursor(toName: "notes.txt")
        bench.commands.perform(.compareByContent)
        // Nothing can be changed outside edit mode.
        session.copy(rows: 1..<2, to: .right)
        #expect(fixture.rows()[1] == "two|2" && !session.hasUnsavedChanges)

        session.setEditing(true)
        session.copy(rows: 1..<2, to: .right)
        #expect(fixture.rows() == ["one|one", "two|two", "three|three", "four|four", "~|five"])
        #expect(
            session.modified.right && !session.modified.left && session.label(.right, row: 1) == "0"
                && session.status.contains("[modified]")
        )
        // The line the left does not have is taken over from the right…
        session.copy(rows: 4..<5, to: .left)
        #expect(fixture.rows().last == "five|five" && session.blocks.isEmpty && session.modified.left)
        session.undo()
        #expect(fixture.rows().last == "~|five" && !session.modified.left && session.modified.right)
        // …or removed on the right by copying the left's nothing.
        session.copy(rows: 4..<5, to: .right)
        #expect(fixture.rows() == ["one|one", "two|two", "three|three", "four|four"] && session.canUndo)
        session.undo()
        session.undo()
        #expect(fixture.rows()[1] == "two|2" && !session.hasUnsavedChanges && !session.canUndo)

        session.copy(rows: 1..<2, to: .left)
        session.setText("FOUR and more", .left, row: 3)
        session.setText("three", .left, row: 2)  // unchanged text is no edit
        #expect(fixture.rows() == ["one|one", "2|2", "three|three", "FOUR and more|four", "~|five"])
        session.save()
        #expect(bench.jobService.titles == ["Save"])
        #expect(
            memory.contents("/A/notes.txt") == "one\n2\nthree\nFOUR and more\n"
                && memory.contents("/B/notes.txt") == "one\n2\nthree\nfour\nfive\n"
        )
        #expect(!session.hasUnsavedChanges && !memory.allPaths.contains { $0.contains("afm-save") })
        #expect(bench.left.model.items.first { $0.name == "notes.txt" }?.size == 26)
    }

    /// Whole blocks and inserted lines go to the right place, with the target's line break.
    @Test
    internal func wholeBlocksAndInsertionsGoToTheRightPlace() {
        memory.addFile("/A/block.txt", "head\na1\na2\na3\ntail")
        memory.addFile("/B/block.txt", "head\r\nb1\r\ntail\r\nextra\r\n")
        fixture.compare("block.txt")
        #expect(fixture.rows() == ["head|head", "a1|b1", "a2|~", "a3|~", "tail|tail", "~|extra"])
        session.setEditing(true)
        session.copy(rows: session.blocks[0], to: .right)
        #expect(fixture.rows() == ["head|head", "a1|a1", "a2|a2", "a3|a3", "tail|tail", "~|extra"])
        session.copy(rows: 5..<6, to: .left)
        session.save()
        // Copied lines take the line break the target file mostly uses.
        #expect(memory.contents("/B/block.txt") == "head\r\na1\r\na2\r\na3\r\ntail\r\nextra\r\n")
        #expect(memory.contents("/A/block.txt") == "head\na1\na2\na3\ntail\nextra\n")
    }

    /// A save that fails is reported, and the changes stay.
    @Test
    internal func aFailedSaveIsReportedAndTheChangesStay() {
        bench.left.moveCursor(toName: "notes.txt")
        bench.commands.perform(.compareByContent)
        session.setEditing(true)
        session.copy(rows: 1..<2, to: .right)
        memory.removeTree("/B")
        var answers: [Bool] = []
        session.save { saved in answers.append(saved) }
        #expect(
            answers == [false] && session.hasUnsavedChanges
                && interaction.log.last == "inform: mem:/B/notes.txt could not be saved."
        )
    }

    /// UTF-16 and Latin-1 files are saved in their own encodings.
    @Test
    internal func encodingsSurviveEditing() throws {
        let box = try Sandbox()
        try (Data([0xFF, 0xFE]) + (try #require("erste\r\nzweite\r\n".data(using: .utf16LittleEndian))))
            .write(
                to: box.url("utf16.txt")
            )
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0A, 0x7A, 0x77, 0x65, 0x69, 0x74, 0x65, 0x0A])
            .write(
                to: box.url("latin.txt")
            )
        _ = fixture.operands(.text(box.url("utf16.txt").absoluteString + "\n" + box.url("latin.txt").absoluteString))
        #expect(
            session.status == "1 difference    UTF-16 LE <-> Latin-1"
                && fixture.rows() == ["erste|café", "zweite|zweite"]
        )
        session.setEditing(true)
        session.copy(rows: 0..<1, to: .left)
        session.setText("dritte", .right, row: 1)
        session.save()
        #expect(
            try Data(contentsOf: box.url("utf16.txt"))
                == Data([0xFF, 0xFE]) + (try #require("café\r\nzweite\r\n".data(using: .utf16LittleEndian)))
        )
        #expect(
            try Data(contentsOf: box.url("latin.txt"))
                == Data([0x63, 0x61, 0x66, 0xE9, 0x0A, 0x64, 0x72, 0x69, 0x74, 0x74, 0x65, 0x0A])
        )
    }
}

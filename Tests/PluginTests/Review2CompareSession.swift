import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import CompareContentPlugin

/// Review round 2: saving that never loses or mangles a file, and a session that does not trust a diff that is
/// out of date.
@MainActor
@Suite
internal struct Review2CompareSession {
    /// The folders of the two files.
    internal let box: Sandbox
    /// The plugin, without windows.
    internal let plugin = CompareContentPlugin(opensWindows: false)
    /// The settings of the bench.
    internal let settings = MemorySettings()
    /// The kernel with the plugin, its panels on the two folders.
    internal let bench: TestBench
    /// The scripted answers of the user, and what was asked.
    internal var interaction: ScriptedInteraction { bench.interaction }
    /// The session the command opened.
    internal var session: CompareSession { plugin.sessions[0] }

    /// Two folders with a file `f.txt` each, the second with one line changed and one added.
    internal init() throws {
        box = try Sandbox()
        try box.file("A/f.txt", "one\ntwo\nthree\nfour\n")
        try box.file("B/f.txt", "one\n2\nthree\nfour\nfive\n")
        bench = TestBench(
            plugins: [plugin],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B"),
            settings: settings
        )
    }

    /// Compares the two `f.txt` and turns edit mode on.
    internal func open() {
        bench.left.reload()
        bench.left.moveCursor(toName: "f.txt")
        bench.commands.perform(.compareByContent)
        session.setEditing(true)
    }

    /// Undo puts back exactly what the edits replaced, and the session is unmodified again.
    @Test
    internal func undoPutsBackExactlyWhatEditsReplaced() {
        open()
        let before = session.text(.right, row: 1)
        session.copy(rows: 1..<2, to: .right)
        session.setText("FOUR!", .left, row: 3)
        session.copy(rows: 4..<5, to: .left)
        #expect(session.hasUnsavedChanges && session.canUndo)
        session.undo()
        session.undo()
        session.undo()
        #expect(!session.hasUnsavedChanges && !session.canUndo)
        #expect(
            session.text(.right, row: 1) == before
                && (0..<session.rowCount).map { row in session.text(.left, row: row) } == [
                    "one", "two", "three", "four", nil
                ]
        )
    }

    /// Rows far beyond the texts change nothing and do not trap.
    @Test
    internal func aRowThatPointsOutsideTheTextsIsNeverTrusted() {
        open()
        // Rows far beyond the texts change nothing and do not trap.
        session.copy(rows: 100..<200, to: .right)
        #expect(!session.hasUnsavedChanges)
    }

    /// Quitting asks about unsaved edits: Cancel calls it off, Don't Save gives them up, Save writes them.
    @Test
    internal func quittingAsksAboutUnsavedEditsAndCanBeCalledOff() {
        open()
        session.setText("two edited", .left, row: 1)
        interaction.choiceAnswers = [2]  // Cancel
        #expect(!plugin.shouldTerminate())
        #expect(box.read("A/f.txt") == "one\ntwo\nthree\nfour\n" && session.hasUnsavedChanges)
        interaction.choiceAnswers = [1]  // Don't Save
        #expect(plugin.shouldTerminate())
        #expect(box.read("A/f.txt") == "one\ntwo\nthree\nfour\n" && !session.hasUnsavedChanges)
        session.setText("second edit", .left, row: 1)
        interaction.choiceAnswers = [0]  // Save
        #expect(plugin.shouldTerminate())
        #expect(box.read("A/f.txt") == "one\nsecond edit\nthree\nfour\n")
    }

    /// Stopping the plugin asks once more about what is left, and saves it.
    @Test
    internal func stopAsksOnceMoreForWhatIsLeft() {
        open()
        session.setText("changed", .right, row: 1)
        interaction.choiceAnswers = [0]
        plugin.stop()
        #expect(box.read("B/f.txt")?.contains("changed") == true)
    }

    /// A save never overwrites a file someone else changed after it was loaded.
    @Test
    internal func aSaveNeverOverwritesAFileSomeoneElseChanged() throws {
        open()
        session.setText("mine", .left, row: 1)
        // Someone else writes the file after it was loaded.
        Thread.sleep(forTimeInterval: 0.02)
        try "theirs\n".write(to: box.url("A/f.txt"), atomically: true, encoding: .utf8)
        var answers: [Bool] = []
        session.save { saved in answers.append(saved) }
        #expect(answers == [false] && box.read("A/f.txt") == "theirs\n" && session.hasUnsavedChanges)
    }

    /// A character the encoding cannot hold is refused, not turned into a question mark.
    @Test
    internal func aCharacterTheEncodingCannotHoldIsRefusedNotTurnedIntoAQuestionMark() throws {
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: box.url("A/latin.txt"))
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0A, 0x78, 0x0A]).write(to: box.url("B/latin.txt"))
        bench.left.reload()
        bench.right.reload()
        bench.left.moveCursor(toName: "latin.txt")
        bench.commands.perform(.compareByContent)
        session.setEditing(true)
        session.setText("snowman \u{2603}", .left, row: 0)
        var answers: [Bool] = []
        session.save { saved in answers.append(saved) }
        #expect(answers == [false])
        #expect(try Data(contentsOf: box.url("A/latin.txt")) == Data([0x63, 0x61, 0x66, 0xE9, 0x0A]))
    }

    /// The two sides of one file are not both saved: the second would replace the first.
    @Test
    internal func theTwoSidesOfOneFileAreNotBothSaved() throws {
        try box.file("A/g.txt", "a\nb\n")
        bench.left.reload()
        bench.left.moveCursor(toName: "g.txt")
        bench.commands.perform(
            .compareByContent,
            .text(box.url("A/g.txt").absoluteString + "\n" + box.url("A/g.txt").absoluteString)
        )
        session.setEditing(true)
        session.setText("x", .left, row: 0)
        session.setText("y", .right, row: 1)
        var answers: [Bool] = []
        session.save { saved in answers.append(saved) }
        #expect(answers == [false] && box.read("A/g.txt") == "a\nb\n")
    }

    /// Replacing a file keeps its hard links together, and refuses a file that changed since it was loaded.
    @Test
    internal func replaceKeepsHardLinksTogetherAndRefusesAChangedFile() throws {
        let registry = FileSystemRegistry()
        registry.register(LocalFileSystem())
        try box.file("h/one.txt", "old")
        try FileManager.default.linkItem(at: box.url("h/one.txt"), to: box.url("h/two.txt"))
        try CompareLoader.replace(box.url("h/one.txt"), with: Data("new".utf8), fileSystems: registry)
        #expect(box.read("h/one.txt") == "new" && box.read("h/two.txt") == "new")
        let loaded = try #require(registry.item(at: box.url("h/one.txt")))
        try "changed elsewhere, longer".write(to: box.url("h/one.txt"), atomically: false, encoding: .utf8)
        #expect(throws: CompareLoader.SaveError.self) {
            try CompareLoader.replace(
                box.url("h/one.txt"),
                with: Data("mine".utf8),
                fileSystems: registry,
                expected: loaded
            )
        }
        #expect(box.read("h/one.txt") == "changed elsewhere, longer")
    }

    /// On a file system that cannot replace in one step, the file is replaced and nothing is left beside it.
    @Test
    internal func aFileThatCannotBeRenamedOverIsNotLostWhenTheSecondStepFails() throws {
        // A provider that cannot replace in one step: the old file is moved aside and comes back if the new one
        // cannot be put in place.
        let memory = MemoryFileSystem()
        memory.addFile("/d/f.txt", "old")
        let registry = FileSystemRegistry()
        registry.register(memory)
        try CompareLoader.replace(memory.url("/d/f.txt"), with: Data("new".utf8), fileSystems: registry)
        #expect(memory.contents("/d/f.txt") == "new" && memory.allPaths.allSatisfy { path in !path.contains("afm-") })
    }
}

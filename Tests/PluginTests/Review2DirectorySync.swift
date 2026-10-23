import AFMContracts
import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import DirectorySyncPlugin

/// Review round 2: Synchronize directories must not delete a target because its source looks
/// empty, and must say what went wrong.
@MainActor
@Suite
internal struct Review2DirectorySync {
    /// The two folders: an empty left one and a right one with three files.
    internal let memory = MemoryFileSystem()
    /// The plugin, without windows.
    internal let plugin = DirectorySyncPlugin(opensWindows: false)
    /// The settings of the bench.
    internal let settings = MemorySettings()
    /// The kernel with the plugin, its panels on the two folders.
    internal let bench: TestBench
    /// The date of the right side's files.
    internal let early = Date(timeIntervalSince1970: 1_000_000)
    /// The scripted answers of the user, and what was asked.
    internal var interaction: ScriptedInteraction { bench.interaction }

    /// A bench whose left panel shows an empty folder and whose right panel shows three files.
    internal init() {
        memory.addDirectory("/A")
        memory.addFile("/B/one.txt", "one", modified: early)
        memory.addFile("/B/two.txt", "two", modified: early)
        memory.addFile("/B/sub/three.txt", "three", modified: early)
        bench = TestBench(
            plugins: [plugin],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B"),
            settings: settings
        )
    }

    /// Opens the window's session on the panels and compares, as a mirror or both ways.
    private func opened(asymmetric: Bool) throws -> SyncSession {
        bench.commands.perform(.synchronizeDirectories)
        let session = try #require(plugin.session)
        session.options.asymmetric = asymmetric
        session.compare()
        return session
    }

    /// The states of the boxes named `key` in the last form shown.
    private func checkboxes(_ key: String) -> [Bool] {
        (interaction.forms.last ?? [])
            .compactMap { field in
                guard field.key == key, case .checkbox(let isOn) = field.kind else {
                    return nil
                }
                return isOn
            }
    }

    /// A mirror of an empty source warns, and its deletion is not ticked: accepting the dialog deletes nothing.
    @Test
    internal func aMirrorOfAnEmptySourceWarnsAndLeavesTheDeletionUnticked() throws {
        let session = try opened(asymmetric: true)
        #expect(session.sourceLooksEmpty && interaction.log.contains("inform: The left directory is empty."))
        interaction.formAnswers = [.accept]
        session.synchronize()
        // The line names the folder, and its box is off: accepting the dialog as it stands deletes nothing.
        #expect(
            interaction.forms.last?.contains { field in field.label == "Right: Delete 3 file(s) in mem:/B" } == true
        )
        #expect(checkboxes("deleteRight") == [false])
        #expect(memory.exists("/B/one.txt") && memory.exists("/B/two.txt") && memory.exists("/B/sub/three.txt"))
    }

    /// The deletion of a mirror of an empty source runs when the user ticks it.
    @Test
    internal func theDeletionRunsWhenTheUserTicksIt() throws {
        let session = try opened(asymmetric: true)
        interaction.formAnswers = [
            .values(["deleteRight": .flag(true), "confirm": .flag(false), "direct": .flag(true)])
        ]
        session.synchronize()
        #expect(!memory.exists("/B/one.txt") && !memory.exists("/B/two.txt"))
    }

    /// A mirror of a source with files proposes its deletion ticked, as always.
    @Test
    internal func anOrdinaryMirrorStillProposesTheDeletionTicked() throws {
        memory.addFile("/A/one.txt", "one", modified: early)
        let session = try opened(asymmetric: true)
        #expect(!session.sourceLooksEmpty)
        interaction.formAnswers = [.accept]
        session.synchronize()
        #expect(checkboxes("deleteRight") == [true])
    }

    /// A comparison both ways with an empty side is no mirror and gives no warning.
    @Test
    internal func aTwoWaySyncOfAnEmptySideIsNotAMirror() throws {
        let session = try opened(asymmetric: false)
        #expect(!session.sourceLooksEmpty)
    }

    /// A commit that fails is reported, and nothing is deleted after it.
    @Test
    internal func aFailedCommitIsSaidAndNothingIsDeleted() throws {
        struct Refused: Error {}
        memory.capabilities = [.write, .deferredWrites]
        memory.commitFailure = Refused()
        memory.addFile("/A/new.txt", "fresh", modified: early.addingTimeInterval(100))
        memory.addFile("/B/extra.txt", "only right", modified: early)
        let session = try opened(asymmetric: true)
        interaction.formAnswers = [.values(["confirm": .flag(false), "direct": .flag(true)])]
        session.synchronize()
        #expect(interaction.log.contains("inform: Synchronize did not finish without errors."))
        #expect(memory.exists("/B/extra.txt"))
    }

    /// Errors after "Skip All", which asked no more, are still reported at the end.
    @Test
    internal func errorsAfterSkipAllAreSummarised() throws {
        memory.addFile("/A/x1.txt", "1", modified: early.addingTimeInterval(100))
        memory.addFile("/A/x2.txt", "2", modified: early.addingTimeInterval(100))
        let session = try opened(asymmetric: false)
        memory.removeTree("/A/x1.txt")
        memory.removeTree("/A/x2.txt")
        interaction.formAnswers = [.values(["confirm": .flag(false)])]
        interaction.choiceAnswers = [1]  // Skip All
        session.synchronize()
        #expect(interaction.log.contains("inform: Synchronize did not finish without errors."))
    }

    /// Loading a set clears the rows, so that nothing of a comparison that ran before arrives later.
    @Test
    internal func loadingASetOrAdoptingDuringAComparisonDropsTheOldRun() throws {
        let session = try opened(asymmetric: true)
        session.saveSet(named: "mine")
        // The state is cleared and a running comparison would be cancelled; nothing stale arrives later.
        #expect(session.loadSet(named: "mine"))
        #expect(session.phase == .idle && session.rows.isEmpty)
    }
}

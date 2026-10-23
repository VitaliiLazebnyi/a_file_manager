import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import CompareContentPlugin
@testable import DirectorySyncPlugin

/// Synchronize directories run through its session: the dialog, the actions of the rows, and what the
/// run does with the files.
///
/// No window is involved.
@MainActor
@Suite
internal struct DirectorySyncRuns {
    /// The folders, the plugins and the bench.
    private let fixture = DirectorySyncFixture()

    /// The two folders.
    private var memory: MemoryFileSystem { fixture.memory }
    /// The plugin.
    private var plugin: DirectorySyncPlugin { fixture.plugin }
    /// The comparison tool.
    private var compareTool: CompareContentPlugin { fixture.compareTool }
    /// The settings of the bench.
    private var settings: MemorySettings { fixture.settings }
    /// The kernel with both plugins.
    private var bench: TestBench { fixture.bench }
    /// The scripted answers of the user, and what was asked.
    private var interaction: ScriptedInteraction { fixture.interaction }

    /// Synchronize copies both ways after the dialog and an overwrite question, and compares again.
    @Test
    internal func synchronizeRunsBothDirectionsAndComparesAgain() throws {
        let session = try fixture.opened()
        #expect(session.canSynchronize)
        interaction.formAnswers = [.accept]
        interaction.choiceAnswers = [1]  // Overwrite All
        session.synchronize()

        let form = interaction.forms.last?.map(\.label) ?? []
        #expect(
            form == [
                "Left to right: Copy 2 files, total size: 30 bytes", "Target:",
                "Right to left: Copy 2 files, total size: 32 bytes",
                "Target:", "Confirm overwrites"
            ]
        )
        #expect(interaction.log.contains { $0.hasPrefix("choose: Overwrite mem:/A/back.txt?") })
        #expect(bench.jobService.titles == ["Synchronize"])
        #expect(
            memory.contents("/B/new.txt") == "from the left" && memory.contents("/B/update.txt") == "newer on the left"
        )
        #expect(
            memory.contents("/A/back.txt") == "newer on the right"
                && memory.contents("/A/sub/arrives.txt") == "from the right"
        )
        #expect(memory.contents("/A/odd.txt") == "left text" && memory.contents("/B/odd.txt") == "right text!")
        // The comparison ran again and the panels show the new files.
        #expect(session.status == "Files found: 6  (Identical: 5, Different: 1, Unique left: 0, Unique right: 0)")
        #expect(!session.canSynchronize)
        #expect(bench.left.names.contains("sub") && bench.right.names.contains("new.txt"))
    }

    /// The dialog decides what runs: nothing when cancelled, one direction into another folder, and the list is
    /// emptied when it is not to be compared again.
    @Test
    internal func theDialogDecidesWhatRuns() throws {
        var session = try fixture.opened()
        interaction.formAnswers = [.cancel]
        session.synchronize()
        #expect(!memory.exists("/B/new.txt") && bench.jobService.titles.isEmpty)

        // Only left to right, into another folder, without asking about overwrites.
        interaction.formAnswers = [
            .values(["toLeft": .flag(false), "rightTarget": .text("mem:/Backup"), "confirm": .flag(false)])
        ]
        session.synchronize()
        #expect(
            memory.contents("/Backup/new.txt") == "from the left"
                && memory.contents("/Backup/update.txt") == "newer on the left"
        )
        #expect(
            memory.contents("/A/back.txt") == "older" && memory.contents("/B/update.txt") == "older"
                && !memory.exists("/A/sub")
        )
        #expect(!interaction.log.contains { $0.hasPrefix("choose:") })

        // Without re-comparing, the list is emptied afterwards (`SyncRecompareAfterCopy=0`).
        settings.set(false, forKey: "directorySync.recompareAfterSync")
        session = try fixture.opened()
        interaction.formAnswers = [.values(["confirm": .flag(false)])]
        session.synchronize()
        #expect(
            memory.contents("/A/back.txt") == "newer on the right" && session.rows.isEmpty
                && session.status == "Please press 'Compare' to start"
        )
    }

    /// Only the rows the Show buttons let through are synchronized.
    @Test
    internal func onlyVisibleRowsAreSynchronized() throws {
        let session = try fixture.opened()
        session.show = [.copyToLeft, .duplicates, .singles]
        interaction.formAnswers = [.values(["confirm": .flag(false)])]
        session.synchronize()
        #expect(interaction.forms.last?.map(\.key) == ["toLeft", "leftTarget", "confirm"])
        #expect(memory.contents("/A/back.txt") == "newer on the right" && memory.exists("/A/sub/arrives.txt"))
        #expect(!memory.exists("/B/new.txt") && memory.contents("/B/update.txt") == "older")
    }

    /// The actions of one row or many are set, reversed, toggled and cycled, and the run does what they say.
    @Test
    internal func directionsAreChangedForOneRowOrMany() throws {
        let session = try fixture.opened()
        func actions(_ names: String...) -> [SyncAction] {
            fixture.rows(session, names[0], names.count > 1 ? names[1] : names[0]).map { session.rows[$0].action }
        }

        session.setAction(.copyToLeft, rows: fixture.rows(session, "update.txt", "new.txt", "odd.txt"))
        // A file that exists only on the left cannot be copied from the right.
        #expect(
            actions("update.txt") == [.copyToLeft] && actions("new.txt") == [.copyToRight]
                && actions("odd.txt") == [.copyToLeft]
        )
        session.reverse(rows: fixture.rows(session, "update.txt", "odd.txt", "back.txt"))
        #expect(
            actions("update.txt") == [.copyToRight] && actions("odd.txt") == [.copyToRight]
                && actions("back.txt") == [.copyToRight]
        )
        session.setAction(.nothing, rows: fixture.rows(session, "back.txt", "new.txt"))
        #expect(actions("back.txt", "new.txt") == [.nothing, .nothing])
        session.toggle(rows: fixture.rows(session, "back.txt", "new.txt", "update.txt"))
        #expect(
            actions("back.txt", "new.txt") == [.copyToLeft, .copyToRight]
                && actions("update.txt") == [SyncAction.nothing]
        )
        session.markDefault(rows: Array(session.rows.indices))
        #expect(session.rows.allSatisfy { $0.action == $0.defaultAction })
        session.cycle(row: fixture.rows(session, "odd.txt")[0])
        #expect(actions("odd.txt") == [.copyToRight])
        session.setAction(.deleteBoth, rows: fixture.rows(session, "same.txt", "new.txt"))
        session.setAction(.deleteRight, rows: fixture.rows(session, "arrives.txt"))
        session.setAction(.nothing, rows: fixture.rows(session, "back.txt", "update.txt"))

        interaction.formAnswers = [.values(["confirm": .flag(false)])]
        session.synchronize()
        #expect(
            interaction.forms.last?.map(\.label) == [
                "Left to right: Copy 2 files, total size: 22 bytes", "Target:", "Right: Delete 2 file(s) in mem:/B",
                "Left: Delete 1 file(s) in mem:/A", "Confirm overwrites",
                "Delete directly instead of moving to the Trash"
            ]
        )
        #expect(memory.contents("/B/odd.txt") == "left text" && memory.contents("/B/new.txt") == "from the left")
        #expect(!memory.exists("/A/same.txt") && !memory.exists("/B/same.txt") && !memory.exists("/B/sub/arrives.txt"))
        #expect(memory.contents("/B/update.txt") == "older" && memory.contents("/A/back.txt") == "older")
    }

    /// A mirror deletes on the right, empty folders included, and never copies to the left.
    @Test
    internal func asymmetricDeletesOnTheRightAfterConfirmation() throws {
        let session = try fixture.opened { opened in
            opened.options.asymmetric = true
            opened.options.emptyDirectories = true
        }
        interaction.formAnswers = [.values(["emptyDirectories": .flag(true), "confirm": .flag(false)])]
        session.synchronize()
        #expect(interaction.forms.last?.map(\.label).contains("Right: Delete 2 file(s) in mem:/B") == true)
        #expect(interaction.forms.last?.map(\.label).contains("Right: Delete all empty directories in mem:/B") == true)
        #expect(!memory.exists("/B/sub") && memory.contents("/B/update.txt") == "newer on the left")
        // Newer on the right is never taken to the left in this mode, and not overwritten either.
        #expect(memory.contents("/A/back.txt") == "older" && memory.contents("/B/back.txt") == "newer on the right")
        #expect(!memory.exists("/A/sub"))
    }

    /// A copy that fails is asked about, and the rest of the run still goes on.
    @Test
    internal func failuresAreAskedAboutAndTheRestStillRuns() throws {
        let session = try fixture.opened()
        memory.removeTree("/A/new.txt")
        interaction.formAnswers = [.values(["confirm": .flag(false)])]
        interaction.choiceAnswers = [0]  // Skip
        session.synchronize()
        #expect(interaction.log.contains { $0.hasPrefix("choose: Error with mem:/B/new.txt") })
        #expect(memory.contents("/B/update.txt") == "newer on the left" && !memory.exists("/B/new.txt"))
    }
}

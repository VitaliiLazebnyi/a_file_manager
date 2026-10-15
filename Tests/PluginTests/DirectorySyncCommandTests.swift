import AFMContracts
import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import CompareContentPlugin
@testable import DirectorySyncPlugin

/// Synchronize directories driven through its command and its session, with fake panels, a
/// scripted user and jobs that run at once. No window is involved.
@MainActor @Suite struct DirectorySyncCommands {
    let memory = MemoryFileSystem()
    let plugin = DirectorySyncPlugin(opensWindows: false)
    let compareTool = CompareContentPlugin(opensWindows: false)
    let settings = MemorySettings()
    let bench: TestBench
    let early = Date(timeIntervalSince1970: 1_000_000)

    var ui: ScriptedInteraction { bench.interaction }

    init() {
        memory.addFile("/A/new.txt", "from the left", modified: early.addingTimeInterval(500))
        memory.addFile("/A/update.txt", "newer on the left", modified: early.addingTimeInterval(60))
        memory.addFile("/B/update.txt", "older", modified: early)
        memory.addFile("/A/back.txt", "older", modified: early)
        memory.addFile("/B/back.txt", "newer on the right", modified: early.addingTimeInterval(60))
        memory.addFile("/B/sub/arrives.txt", "from the right", modified: early)
        memory.addFile("/A/same.txt", "same", modified: early)
        memory.addFile("/B/same.txt", "same", modified: early)
        memory.addFile("/A/odd.txt", "left text", modified: early)
        memory.addFile("/B/odd.txt", "right text!", modified: early)
        bench = TestBench(
            plugins: [plugin, compareTool],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B"),
            settings: settings
        )
    }

    /// Opens the tool and compares.
    func opened(_ configure: (SyncSession) -> Void = { _ in }) -> SyncSession {
        bench.commands.perform(.synchronizeDirectories)
        let session = plugin.session!
        configure(session)
        session.compare()
        return session
    }

    func rows(_ session: SyncSession, _ names: String...) -> [Int] {
        session.rows.indices.filter { names.contains(session.rows[$0].name) }
    }

    @Test func commandIsRegisteredWithMenuButtonAndPreferences() {
        #expect(bench.commands[.synchronizeDirectories]?.title == "Synchronize Dirs…")
        #expect(
            bench.kernel.menus.menus.first { $0.title == "Commands" }?.items.contains(.synchronizeDirectories) == true
        )
        #expect(bench.kernel.toolbar.defaultLayout.contains { $0?.command == .synchronizeDirectories })
        #expect(
            bench.kernel.preferences.pages.contains {
                $0.title == "Synchronize directories" && $0.preferences.count == 5
            }
        )
        #expect(bench.kernel.keyClashes.isEmpty)
    }

    @Test func opensWithThePanelsDirectoriesAndSelection() {
        bench.right.focus()
        bench.right.model.select(mask: "same.txt")
        bench.left.model.select(mask: "new.txt")
        bench.commands.perform(.synchronizeDirectories)
        let session = plugin.session!
        // Left stays left, whichever panel is active.
        #expect(session.leftPath == "mem:/A" && session.rightPath == "mem:/B")
        #expect(session.selectedNames == ["new.txt", "same.txt"])
        #expect(
            session.status == "Please press 'Compare' to start" && session.entries.isEmpty && !session.canSynchronize
        )

        session.onlySelected = true
        session.compare()
        #expect(session.rows.map(\.name) == ["new.txt", "same.txt"])
        #expect(session.status == "Files found: 2  (Identical: 1, Different: 0, Unique left: 1, Unique right: 0)")
    }

    @Test func listIsGroupedBySubdirectoryAndFilteredByTheShowButtons() {
        let session = opened()
        #expect(session.entries.count == 7 && session.entries[5] == .header("sub/"))
        #expect(session.status == "Files found: 6  (Identical: 1, Different: 3, Unique left: 1, Unique right: 1)")
        #expect(session.groupIndicator(atEntry: 6) == "1/1 sub/" && session.groupIndicator(atEntry: 0) == "0/1 ")
        #expect(
            session.header(after: 0, forward: true) == 5 && session.header(after: 6, forward: false) == 5
                && session.header(after: 5, forward: true) == nil
        )

        session.show = [.copyToRight, .duplicates, .singles]
        #expect(session.visibleRows.map { session.rows[$0].name } == ["new.txt", "update.txt"])
        #expect(session.status.hasSuffix("[2 shown, 4 hidden by the Show buttons]"))
        session.show = SyncShow.all.subtracting(.duplicates)
        #expect(session.visibleRows.map { session.rows[$0].name } == ["new.txt", "arrives.txt"])
        #expect(session.entries.contains(.header("sub/")))

        session.show = .all
        session.sort = (.size, .left, false)
        #expect(session.visibleRows.prefix(2).map { session.rows[$0].name } == ["update.txt", "new.txt"])
    }

    @Test func synchronizeRunsBothDirectionsAndComparesAgain() {
        let session = opened()
        #expect(session.canSynchronize)
        ui.formAnswers = [.accept]
        ui.choiceAnswers = [1]  // Overwrite All
        session.synchronize()

        let form = ui.forms.last?.map(\.label) ?? []
        #expect(
            form == [
                "Left to right: Copy 2 files, total size: 30 bytes", "Target:",
                "Right to left: Copy 2 files, total size: 32 bytes",
                "Target:", "Confirm overwrites"
            ]
        )
        #expect(ui.log.contains { $0.hasPrefix("choose: Overwrite mem:/A/back.txt?") })
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

    @Test func theDialogDecidesWhatRuns() {
        var session = opened()
        ui.formAnswers = [.cancel]
        session.synchronize()
        #expect(!memory.exists("/B/new.txt") && bench.jobService.titles.isEmpty)

        // Only left to right, into another folder, without asking about overwrites.
        ui.formAnswers = [
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
        #expect(!ui.log.contains { $0.hasPrefix("choose:") })

        // Without re-comparing, the list is emptied afterwards (`SyncRecompareAfterCopy=0`).
        settings.set(false, forKey: "directorySync.recompareAfterSync")
        session = opened()
        ui.formAnswers = [.values(["confirm": .flag(false)])]
        session.synchronize()
        #expect(
            memory.contents("/A/back.txt") == "newer on the right" && session.rows.isEmpty
                && session.status == "Please press 'Compare' to start"
        )
    }

    @Test func onlyVisibleRowsAreSynchronized() {
        let session = opened()
        session.show = [.copyToLeft, .duplicates, .singles]
        ui.formAnswers = [.values(["confirm": .flag(false)])]
        session.synchronize()
        #expect(ui.forms.last?.map(\.key) == ["toLeft", "leftTarget", "confirm"])
        #expect(memory.contents("/A/back.txt") == "newer on the right" && memory.exists("/A/sub/arrives.txt"))
        #expect(!memory.exists("/B/new.txt") && memory.contents("/B/update.txt") == "older")
    }

    @Test func directionsAreChangedForOneRowOrMany() {
        let session = opened()
        func actions(_ names: String...) -> [SyncAction] {
            rows(session, names[0], names.count > 1 ? names[1] : names[0]).map { session.rows[$0].action }
        }

        session.setAction(.copyToLeft, rows: rows(session, "update.txt", "new.txt", "odd.txt"))
        // A file that exists only on the left cannot be copied from the right.
        #expect(
            actions("update.txt") == [.copyToLeft] && actions("new.txt") == [.copyToRight]
                && actions("odd.txt") == [.copyToLeft]
        )
        session.reverse(rows: rows(session, "update.txt", "odd.txt", "back.txt"))
        #expect(
            actions("update.txt") == [.copyToRight] && actions("odd.txt") == [.copyToRight]
                && actions("back.txt") == [.copyToRight]
        )
        session.setAction(.none, rows: rows(session, "back.txt", "new.txt"))
        #expect(actions("back.txt", "new.txt") == [.none, .none])
        session.toggle(rows: rows(session, "back.txt", "new.txt", "update.txt"))
        #expect(
            actions("back.txt", "new.txt") == [.copyToLeft, .copyToRight] && actions("update.txt") == [SyncAction.none]
        )
        session.markDefault(rows: Array(session.rows.indices))
        #expect(session.rows.allSatisfy { $0.action == $0.defaultAction })
        session.cycle(row: rows(session, "odd.txt")[0])
        #expect(actions("odd.txt") == [.copyToRight])
        session.setAction(.deleteBoth, rows: rows(session, "same.txt", "new.txt"))
        session.setAction(.deleteRight, rows: rows(session, "arrives.txt"))
        session.setAction(.none, rows: rows(session, "back.txt", "update.txt"))

        ui.formAnswers = [.values(["confirm": .flag(false)])]
        session.synchronize()
        #expect(
            ui.forms.last?.map(\.label) == [
                "Left to right: Copy 2 files, total size: 22 bytes", "Target:", "Right: Delete 2 file(s) in mem:/B",
                "Left: Delete 1 file(s) in mem:/A", "Confirm overwrites",
                "Delete directly instead of moving to the Trash"
            ]
        )
        #expect(memory.contents("/B/odd.txt") == "left text" && memory.contents("/B/new.txt") == "from the left")
        #expect(!memory.exists("/A/same.txt") && !memory.exists("/B/same.txt") && !memory.exists("/B/sub/arrives.txt"))
        #expect(memory.contents("/B/update.txt") == "older" && memory.contents("/A/back.txt") == "older")
    }

    @Test func asymmetricDeletesOnTheRightAfterConfirmation() {
        let session = opened {
            $0.options.asymmetric = true
            $0.options.emptyDirectories = true
        }
        ui.formAnswers = [.values(["emptyDirectories": .flag(true), "confirm": .flag(false)])]
        session.synchronize()
        #expect(ui.forms.last?.map(\.label).contains("Right: Delete 2 file(s) in mem:/B") == true)
        #expect(ui.forms.last?.map(\.label).contains("Right: Delete all empty directories in mem:/B") == true)
        #expect(!memory.exists("/B/sub") && memory.contents("/B/update.txt") == "newer on the left")
        // Newer on the right is never taken to the left in this mode, and not overwritten either.
        #expect(memory.contents("/A/back.txt") == "older" && memory.contents("/B/back.txt") == "newer on the right")
        #expect(!memory.exists("/A/sub"))
    }

    @Test func failuresAreAskedAboutAndTheRestStillRuns() {
        let session = opened()
        memory.removeTree("/A/new.txt")
        ui.formAnswers = [.values(["confirm": .flag(false)])]
        ui.choiceAnswers = [0]  // Skip
        session.synchronize()
        #expect(ui.log.contains { $0.hasPrefix("choose: Error with mem:/B/new.txt") })
        #expect(memory.contents("/B/update.txt") == "newer on the left" && !memory.exists("/B/new.txt"))
    }

    @Test func unreadableFoldersAreReported() {
        memory.unreadable = ["/B/sub"]
        let session = opened()
        #expect(ui.log.contains { $0.hasPrefix("inform: Some directories or files could not be read") })
        #expect(!session.rows.contains { $0.directory == "sub/" })
    }

    @Test func viewAndCompareGoThroughOtherPluginsCommands() {
        var viewed: [URL] = []
        bench.commands.register(Command(.view, "View"), parameterized: { viewed += [$0.location].compactMap { $0 } })
        let session = opened()
        let odd = rows(session, "odd.txt")[0]
        session.view(.left, row: odd)
        session.view(.right, row: rows(session, "new.txt")[0])  // nothing on the right
        session.view(.right, row: odd)
        #expect(viewed.map(\.path) == ["/A/odd.txt", "/B/odd.txt"])

        session.compareContents(row: odd)
        #expect(
            compareTool.sessions.last?.leftURL?.path == "/A/odd.txt"
                && compareTool.sessions.last?.rightURL?.path == "/B/odd.txt"
        )
        #expect(compareTool.sessions.last?.blocks.count == 1)

        // Two unrelated files: one picked on each side.
        session.pick(.left, row: rows(session, "new.txt")[0])
        session.pick(.right, row: rows(session, "arrives.txt")[0])
        #expect(session.picked.left?.path == "/A/new.txt")
        session.compareContents(row: nil)
        #expect(
            compareTool.sessions.last?.leftURL?.path == "/A/new.txt"
                && compareTool.sessions.last?.rightURL?.path == "/B/sub/arrives.txt"
        )
        #expect(session.picked.left == nil && session.picked.right == nil)
    }

    @Test func settingsAreSavedUnderNamesAndLoaded() {
        var session = opened {
            $0.options.byContent = true
            $0.options.mask = "*.txt | odd*"
            $0.options.toleranceSeconds = 2
            $0.show = SyncShow.all.subtracting(.equal)
        }
        session.saveSet(named: "Backup")
        session.rightPath = "mem:/Elsewhere"
        session.options = SyncOptions()
        session.saveSet(named: "Another")
        #expect(session.savedSets.map(\.name) == ["Another", "Backup"])

        // A new program run: the last options come back, and the named set on request.
        let second = DirectorySyncPlugin(opensWindows: false)
        let other = TestBench(
            plugins: [second],
            fileSystems: [memory],
            left: memory.url("/"),
            right: memory.url("/A"),
            settings: settings
        )
        other.commands.perform(.synchronizeDirectories)
        #expect(second.session?.options.byContent == true && second.session?.options.mask == "*.txt | odd*")
        other.commands.perform(.synchronizeDirectories, .text("=Backup"))
        session = second.session!
        #expect(session.leftPath == "mem:/A" && session.rightPath == "mem:/B" && session.options.toleranceSeconds == 2)
        #expect(session.show == SyncShow.all.subtracting(.equal))
        // `=name` compares at once; equal rows are hidden and odd.txt is masked out.
        #expect(
            session.phase == .compared && session.visibleRows.count == 4
                && !session.rows.contains { $0.name == "odd.txt" }
        )

        other.commands.perform(.synchronizeDirectories, .text("Missing"))
        #expect(other.interaction.log.last == "inform: There are no saved synchronize settings named Missing.")
        session.removeSet(named: "Another")
        #expect(session.savedSets.map(\.name) == ["Backup"])
    }
}

/// The window itself: built, filled by a comparison that runs in the background, and drawn.
@MainActor @Suite struct DirectorySyncWindow {
    @Test func windowShowsABackgroundComparison() async {
        let memory = MemoryFileSystem()
        for index in 0..<40 {
            memory.addFile("/A/d\(index % 4)/f\(index).txt", "left \(index)")
            if index % 3 != 0 { memory.addFile("/B/d\(index % 4)/f\(index).txt", "left \(index)") }
        }
        let plugin = DirectorySyncPlugin()
        let presenter = StabilityPresenter()
        plugin.present = presenter.present
        defer { presenter.closeAll() }
        let bench = TestBench(
            plugins: [plugin],
            fileSystems: [memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
        bench.commands.perform(.synchronizeDirectories)
        let session = plugin.session!
        let window = presenter.open.first { $0.title == "Synchronize directories" }
        #expect(window != nil)
        session.options.byContent = true
        session.compare()
        #expect(session.phase == .comparing)
        // The result comes back over the main queue, which this test shares with every other test
        // of the process: waited for until it is there (the ceiling only ends a comparison that hangs).
        let deadline = Date().addingTimeInterval(Wait.ceiling)
        while session.phase != .compared, Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        #expect(session.phase == .compared && session.rows.count == 40 && session.entries.count == 44)
        #expect(session.status == "Files found: 40  (Identical: 26, Different: 0, Unique left: 14, Unique right: 0)")
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        session.show = [.copyToRight, .duplicates, .singles]
        session.setAction(.none, rows: session.visibleRows)
        window?.displayIfNeeded()
        #expect(!session.canSynchronize)
        plugin.stop()
        #expect(!presenter.isOpen(window))
    }
}

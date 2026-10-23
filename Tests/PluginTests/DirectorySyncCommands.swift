import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import CompareContentPlugin
@testable import DirectorySyncPlugin

/// Synchronize directories driven through its command and its session, with fake panels, a
/// scripted user and jobs that run at once: opening, the list, the files of rows and the saved sets.
///
/// No window is involved.
@MainActor
@Suite
internal struct DirectorySyncCommands {
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

    /// The command is registered with its menu item, its toolbar button and its preference page.
    @Test
    internal func commandIsRegisteredWithMenuButtonAndPreferences() {
        #expect(bench.commands[.synchronizeDirectories]?.title == "Synchronize Dirs…")
        #expect(
            bench.kernel.menus.menus.first { $0.title == "Commands" }?.items.contains(.synchronizeDirectories) == true
        )
        #expect(bench.kernel.toolbar.defaultLayout.contains { $0?.command == .synchronizeDirectories })
        #expect(
            bench.kernel.preferences.pages.contains { page in
                page.title == "Synchronize directories" && page.preferences.count == 5
            }
        )
        #expect(bench.kernel.keyClashes.isEmpty)
    }

    /// The window opens with the panels' directories, left on the left, and the names selected in both.
    @Test
    internal func opensWithThePanelsDirectoriesAndSelection() throws {
        bench.right.focus()
        bench.right.model.select(mask: "same.txt")
        bench.left.model.select(mask: "new.txt")
        bench.commands.perform(.synchronizeDirectories)
        let session = try #require(plugin.session)
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

    /// The list is grouped by subdirectory, filtered by the Show buttons and sorted by a column.
    @Test
    internal func listIsGroupedBySubdirectoryAndFilteredByTheShowButtons() throws {
        let session = try fixture.opened()
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
        session.sort = SyncSort(key: .size, side: .left, ascending: false)
        #expect(session.visibleRows.prefix(2).map { session.rows[$0].name } == ["update.txt", "new.txt"])
    }

    /// Folders that cannot be read are reported and left out of the rows.
    @Test
    internal func unreadableFoldersAreReported() throws {
        memory.unreadable = ["/B/sub"]
        let session = try fixture.opened()
        #expect(interaction.log.contains { $0.hasPrefix("inform: Some directories or files could not be read") })
        #expect(!session.rows.contains { $0.directory == "sub/" })
    }

    /// Viewing a file and comparing two go through the commands of other plugins.
    @Test
    internal func viewAndCompareGoThroughOtherPluginsCommands() throws {
        var viewed: [URL] = []
        bench.commands.register(Command(.view, "View")) { argument in
            if let location = argument.location {
                viewed.append(location)
            }
        }
        let session = try fixture.opened()
        let odd = fixture.rows(session, "odd.txt")[0]
        session.view(.left, row: odd, command: .view)
        session.view(.right, row: fixture.rows(session, "new.txt")[0], command: .view)  // nothing on the right
        session.view(.right, row: odd, command: .view)
        #expect(viewed.map(\.path) == ["/A/odd.txt", "/B/odd.txt"])

        session.compareContents(row: odd)
        #expect(
            compareTool.sessions.last?.leftURL?.path == "/A/odd.txt"
                && compareTool.sessions.last?.rightURL?.path == "/B/odd.txt"
        )
        #expect(compareTool.sessions.last?.blocks.count == 1)

        // Two unrelated files: one picked on each side.
        session.pick(.left, row: fixture.rows(session, "new.txt")[0])
        session.pick(.right, row: fixture.rows(session, "arrives.txt")[0])
        #expect(session.picked.left?.path == "/A/new.txt")
        session.compareContents(row: nil)
        #expect(
            compareTool.sessions.last?.leftURL?.path == "/A/new.txt"
                && compareTool.sessions.last?.rightURL?.path == "/B/sub/arrives.txt"
        )
        #expect(session.picked.left == nil && session.picked.right == nil)
    }

    /// The settings are saved under names and loaded again, also by a later run of the program.
    @Test
    internal func settingsAreSavedUnderNamesAndLoaded() throws {
        var session = try fixture.opened { opened in
            opened.options.byContent = true
            opened.options.mask = "*.txt | odd*"
            opened.options.toleranceSeconds = 2
            opened.show = SyncShow.all.subtracting(.equal)
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
        session = try #require(second.session)
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

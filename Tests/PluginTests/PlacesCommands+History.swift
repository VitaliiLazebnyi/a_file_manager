import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import PlacesPlugin

/// The history commands: the list of a panel's visits, its buttons, its settings, saving and
/// clearing.
extension PlacesCommands {
    /// The history lists the folders the source panel visited, thinned or not, then the frequently used ones.
    @Test
    internal func historyListsTheVisitedDirectoriesOfThePanel() {
        go(left, "/A/docs")
        go(left, "/A/docs/deep")
        go(left, "/C", after: 1)
        go(right, "/C")
        // /A/docs/deep was only passed through; the source panel's own history is shown.
        interaction.formAnswers = [pick(1)]
        commands.perform(.directoryHistory)
        #expect(
            lastRows == [
                "➤ mem:/C", "    mem:/A/docs", "──────  Frequently used  ──────", "    mem:/C   (2)",
                "    mem:/A/docs   (1)",
                "    mem:/A/docs/deep   (1)"
            ]
        )
        #expect(left.model.directory == memory.url("/A/docs"))

        interaction.formAnswers = [.cancel]
        commands.perform(.directoryHistoryUnthinned)
        #expect(lastRows.prefix(3) == ["➤ mem:/A/docs", "    mem:/C", "    mem:/A/docs/deep"])
    }

    /// The history knows the current folder before any move was announced.
    @Test
    internal func historyKnowsTheCurrentDirectoryBeforeAnyEvent() {
        interaction.formAnswers = [.cancel]
        commands.perform(.directoryHistory)
        #expect(lastRows == ["➤ mem:/A", "──────  Frequently used  ──────", "    mem:/A   (1)"])
    }

    /// The buttons of the history open a tab, move the other panel, and remove entries.
    @Test
    internal func historyButtonsOpenTabsAndTheOtherPanelAndRemoveEntries() {
        go(left, "/C")
        go(left, "/A")
        interaction.formAnswers = [pick(1, button: 1)]
        commands.perform(.directoryHistory)
        #expect(left.tabs.count == 2 && left.model.directory == memory.url("/C"))
        // The window shell announces the new tab's directory.
        clock.time += 10
        bench.kernel.panelEvents.post(.locationChanged, from: left)

        interaction.formAnswers = [pick(0, button: 2)]
        commands.perform(.directoryHistory)
        #expect(right.model.directory == memory.url("/C") && left.model.directory == memory.url("/C"))

        // Remove an entry of the history, then one of the frequent folders; the list comes back each time.
        go(left, "/A")
        interaction.formAnswers = [pick(1, button: 3), pick(3, button: 3), .cancel]
        commands.perform(.directoryHistory)
        #expect(lastRows == ["➤ mem:/A", "──────  Frequently used  ──────", "    mem:/A   (2)"])
    }

    /// The settings limit the length of the history, hide the frequently used folders and switch thinning off.
    @Test
    internal func historySettingsLimitTheListAndHideFrequentFolders() {
        for path in ["/C", "/B", "/A/docs", "/A"] { go(left, path) }
        settings.set("2", forKey: PlacesPlugin.Keys.historyShown)
        settings.set(false, forKey: PlacesPlugin.Keys.showFrequent)
        interaction.formAnswers = [.cancel, .cancel]
        commands.perform(.directoryHistory)
        #expect(lastRows == ["➤ mem:/A", "    mem:/A/docs"])
        settings.set(false, forKey: PlacesPlugin.Keys.thinning)
        go(left, "/C", after: 0)
        go(left, "/A", after: 0)
        commands.perform(.directoryHistory)
        #expect(lastRows == ["➤ mem:/A", "    mem:/C"])
    }

    /// The history is saved shortly after a move, or only on request when saving is off, and cleared.
    @Test
    internal func historyIsSavedAndCleared() {
        go(left, "/C")
        // Changes are written shortly after the navigation, not on every step.
        plugin.flushHistory()
        let stored = settings.scoped(to: "places").value(DirectoryHistory.self, forKey: "history.left")
        #expect(stored?.current == memory.url("/C"))
        commands.perform(.clearDirectoryHistory)
        #expect(settings.data(forKey: "places.history.left") == nil)

        settings.set(false, forKey: PlacesPlugin.Keys.saveHistory)
        go(left, "/B")
        plugin.flushHistory()
        #expect(settings.data(forKey: "places.history.left") == nil)
        commands.perform(.saveDirectoryHistory)
        #expect(
            settings.scoped(to: "places").value(DirectoryHistory.self, forKey: "history.left")?.current
                == memory.url("/B")
        )
    }
}

import AFMKernel
import Foundation
import TestSupport
import Testing

/// Saving and loading tab files through the commands.
extension FolderTabCommands {
    /// Tab files are saved, appended and loaded in place of the tabs, one side or both.
    @Test
    internal func savesAndLoadsTabFiles() throws {
        left.tabs.openTab(showing: memory.url("/A/docs"), activate: true)
        left.model.customTitle = "Papers"
        interaction.promptAnswers = [.text("mem:/B/mine")]
        commands.perform("SAVETABS")
        #expect(interaction.log.contains("prompt: Save tabs to file: [mem:/A/docs/tabs.tab]"))
        let saved = try #require(memory.contents("/B/mine.tab"))
        #expect(
            saved.hasPrefix("[activetabs]\n0_path=mem:/A\n") && saved.contains("1_caption=Papers")
                && !saved.contains("[inactivetabs]")
        )
        #expect(right.names == ["mine.tab", "other.txt"] && bench.jobService.titles == ["Save tabs"])

        // Appending keeps the tabs and the active one; replacing takes the file's.
        right.focus()
        commands.perform("APPENDTABS", .location(memory.url("/B/mine.tab")))
        #expect(
            paths(right) == ["/B", "/A", "/A/docs"] && right.tabs.activeIndex == 0
                && right.tabs.title(at: 2) == "Papers"
        )
        right.tabs.tabs[0].isLocked = true
        commands.perform("OPENTABS", .text("mine.tab"))
        #expect(paths(right) == ["/A", "/A/docs"] && right.tabs.activeIndex == 1 && right.names == ["in.txt"])

        // Saving again asks before the file is replaced.
        interaction.choiceAnswers = [1]
        commands.perform("SAVETABS2", .location(memory.url("/B/mine.tab")))
        #expect(memory.contents("/B/mine.tab") == saved)
        interaction.choiceAnswers = [0]
        commands.perform("SAVETABS2", .location(memory.url("/B/mine.tab")))
        let both = try #require(memory.contents("/B/mine.tab"))
        #expect(both.contains("[inactivetabs]"))

        // A file with both sides fills both panels, its first section going to the source.
        left.focus()
        left.tabs.closeTab(at: 1)
        commands.perform("OPENTABS", .location(memory.url("/B/mine.tab")))
        #expect(paths(left) == ["/A", "/A/docs"] && paths(right) == ["/A", "/A/docs"])
    }

    /// A missing tab file, or one without tabs, is reported and changes nothing.
    @Test
    internal func aMissingOrEmptyTabFileIsReported() {
        commands.perform("OPENTABS", .location(memory.url("/B/none.tab")))
        #expect(interaction.log.last == "inform: The tabs could not be loaded." && left.tabs.count == 1)
        commands.perform("OPENTABS", .location(memory.url("/B/other.txt")))
        #expect(interaction.log.last == "inform: The file holds no tabs." && left.tabs.count == 1)
        interaction.promptAnswers = [.cancel]
        commands.perform("SAVETABS")
        #expect(bench.jobService.titles == ["Load tabs", "Load tabs"])
    }
}

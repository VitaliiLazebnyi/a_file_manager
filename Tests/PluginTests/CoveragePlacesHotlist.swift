import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import PlacesPlugin

/// The hotlist value: levels that do not exist, trimming, damaged lists and quoting.
@Suite
internal struct CoveragePlacesHotlist {
    /// An item, a submenu with two items, and another item.
    internal let sample = Hotlist(entries: [
        .item("A", command: "cd /a"),
        .submenu("S", [.item("In", command: "cd /in"), .item("In2", command: "cd /in2")]),
        .item("B", command: "cd /b")
    ])

    /// A level that does not exist has no entries, and nothing in it can be removed or changed.
    @Test
    internal func aLevelThatDoesNotExistIsEmptyAndCannotBeChanged() {
        var list = sample
        #expect(list.children(of: [7]).isEmpty && list.children(of: [0, 3]).isEmpty)
        #expect(list.remove(at: []) == nil && list.remove(at: [9, 0]) == nil)
        #expect(!list.update(at: []) { $0.title = "x" } && !list.update(at: [9, 0]) { $0.title = "x" })
        #expect(!list.update(at: [1, 5]) { $0.title = "x" })
        #expect(list == sample)
    }

    /// Trimming counts what it cuts off, with everything inside the submenus cut.
    @Test
    internal func trimmingCountsWhatIsCutOffWithEverythingInside() {
        var entries: [HotlistEntry] = [
            .item("kept", command: ""),
            .submenu("cut", [.submenu("inner", [.item("deep", command: "")]), .separator])
        ]
        var room = 1
        #expect(Hotlist.trimmed(&entries, room: &room) == 4)
        #expect(entries.map(\.title) == ["kept"] && room == 0)
    }

    /// A move by nothing, from a level that does not exist or past an end, leaves the list alone.
    @Test
    internal func aMoveThatGoesNowhereLeavesTheListAlone() {
        var list = sample
        #expect(list.move(at: [0], by: 0) == [0] && list.move(at: [], by: 1).isEmpty)
        #expect(list.move(at: [0], by: -1) == [0] && list.move(at: [9], by: 1) == [9])
        #expect(list.move(at: [5, 0, 0], by: 1) == [5, 0, 0] && list.move(at: [1, 7], by: 1) == [1, 7])
        #expect(list == sample)
    }

    /// Entries move into and out of submenus as if the list were flat.
    @Test
    internal func entriesMoveIntoAndOutOfSubmenusAsInAFlatList() {
        var list = sample
        #expect(list.move(at: [0], by: 1) == [0, 0])
        #expect(list.entries[0].children.map(\.title) == ["A", "In", "In2"])
        #expect(list.move(at: [0, 0], by: -1) == [0])
        #expect(list == sample)
        #expect(list.move(at: [2], by: -1) == [1, 2] && list.entries[1].children.last?.title == "B")
        #expect(list.move(at: [1, 2], by: 1) == [2] && list == sample)
    }

    /// An entry inside an item, as damaged data can have it, is moved out once, not doubled.
    @Test
    internal func anEntryInsideADamagedItemIsTakenOutNotDoubled() {
        // Read from damaged data: an item holding entries. The editor lists them; a move takes
        // the entry out to the level of the item, once.
        var list = Hotlist(entries: [
            HotlistEntry(kind: .item, title: "Odd", children: [.item("x", command: ""), .submenu("y")])
        ])
        #expect(list.move(at: [0, 0], by: 1) == [1])
        #expect(list.entries.map(\.title) == ["Odd", "x"] && list.entries[0].children.map(\.title) == ["y"])
        #expect(list.count == 3)
    }

    /// Without a hide character nothing is marked.
    @Test
    internal func withoutAHideCharacterNothingIsMarked() {
        var list = sample
        list.hideCharacter = ""
        list.toggleHideMark(at: [0])
        #expect(list == Hotlist(entries: sample.entries, hideCharacter: ""))
    }

    /// The command for an empty path needs no quotes.
    @Test
    internal func anEmptyPathNeedsNoQuotes() {
        #expect(HotlistAction.changeDirectoryCommand(to: "") == "cd ")
    }
}

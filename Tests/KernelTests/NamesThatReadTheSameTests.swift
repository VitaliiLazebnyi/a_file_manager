import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Two entries whose names read the same and are written differently, as a server or a disk
/// from elsewhere can hold them: each is an entry of its own in everything the panel does.
@MainActor
@Suite
internal struct NamesThatReadTheSameTests {
    private let memory = MemoryFileSystem()
    private let fileSystems = FileSystemRegistry()
    private let composed = "caf\u{E9}"
    private let decomposed = "cafe\u{301}"

    /// The file systems the panels read through: the memory file system alone.
    internal init() {
        fileSystems.register(memory)
    }

    /// The memory file system keeps both spellings apart, though Swift's strings call them equal.
    @Test
    internal func theFileSystemKeepsBothAndTheyAreEqualAsStrings() throws {
        let model = try panel(others: 0)
        #expect(composed == decomposed)
        #expect(Array(composed.utf8) != Array(decomposed.utf8))
        #expect(model.items.count == 4)
        #expect(Set(bytes(model.items)).count == 4)
        #expect(Set(model.items.map(\.name)).count == 2)
        #expect(memory.contents("/d/\(composed).txt") == "12")
        #expect(memory.contents("/d/\(decomposed).txt") == "123")
        let item = memory.item(at: memory.url("/d/\(decomposed).txt"))
        #expect(item.map { Array($0.name.utf8) } == Array("\(decomposed).txt".utf8))
    }

    /// A mark set on one row belongs to that entry alone: count, operands and totals follow it.
    ///
    /// A short list is walked; a long one is looked up through an index. Both must tell the two apart.
    @Test(arguments: [0, 200])
    internal func aMarkOnOneIsNotAMarkOnTheOther(others: Int) throws {
        let model = try panel(others: others)
        let (one, two) = (try row(model, "\(composed).txt"), try row(model, "\(decomposed).txt"))
        #expect(one != two)
        #expect(model.row(ofName: "\(composed).txt") == one)
        #expect(model.row(ofName: "\(decomposed).txt") == two)
        model.toggleSelection(row: two)
        #expect(model.isSelected(row: two))
        #expect(!model.isSelected(row: one))
        #expect(model.selectionCount == 1)
        #expect(bytes(model.operands()) == [Array("\(decomposed).txt".utf8)])
        #expect(model.operands().first?.size == 3)
        #expect(model.totals.selectedFiles == 1)
        #expect(model.totals.selectedBytes == 3)
        #expect(model.hasOperandFile)
        // The set of names cannot tell them apart; it says that something of that name is marked.
        #expect(model.selection == ["\(composed).txt"])
        model.toggleSelection(row: one)
        #expect(model.selectionCount == 2)
        #expect(model.selection.count == 1)
        #expect(model.totals.selectedBytes == 5)
        #expect(model.operands().count == 2)
        model.toggleSelection(row: two)
        #expect(model.isSelected(row: one))
        #expect(!model.isSelected(row: two))
        #expect(model.operands().first?.size == 2)
        #expect(model.selection == ["\(decomposed).txt"])
        #expect(model.totals.selectedBytes == 2)
    }

    /// Ranges, and every way of marking by name, go by the name as it is written.
    @Test(arguments: [0, 200])
    internal func marksByRangeAndByNameGoByTheNameAsWritten(others: Int) throws {
        let model = try panel(others: others)
        let (one, two) = (try row(model, "\(composed).txt"), try row(model, "\(decomposed).txt"))
        model.setSelected(true, rows: two...two)
        #expect(bytes(model.operands()) == [Array("\(decomposed).txt".utf8)])
        model.setSelected(false, names: ["\(composed).txt"])
        #expect(model.selectionCount == 1)
        #expect(model.isSelected(row: two))
        model.setSelected(false, names: ["\(decomposed).txt"])
        #expect(model.selectionCount == 0)
        model.setSelected(true, names: ["\(composed).txt"])
        #expect(model.isSelected(row: one))
        #expect(!model.isSelected(row: two))
        model.setSelection(names: ["\(decomposed).txt", decomposed])
        #expect(!model.isSelected(row: one))
        #expect(model.isSelected(row: two))
        #expect(model.isSelected(row: try row(model, decomposed)))
        #expect(!model.isSelected(row: try row(model, composed)))
        #expect(model.selectionCount == 2)
        #expect(!model.operands().contains { $0.size == 2 })
        model.deselect([decomposed])
        #expect(model.selectionCount == 1)
        #expect(model.isSelected(row: two))
        model.deselect(["\(composed).txt"])
        #expect(model.selectionCount == 1)
        #expect(model.isSelected(row: two))
    }

    /// Everything, the opposite, a mask and what was saved keep the two apart as well.
    @Test(arguments: [0, 200])
    internal func wholeListMarksKeepTheTwoApart(others: Int) throws {
        let model = try panel(others: others)
        let (one, two) = (try row(model, "\(composed).txt"), try row(model, "\(decomposed).txt"))
        model.toggleSelection(row: two)
        model.invertSelection()
        #expect(model.selectionCount == model.items.count - 1)
        #expect(!model.isSelected(row: two))
        #expect(model.isSelected(row: one))
        model.saveSelection()
        model.selectAll()
        #expect(model.selectionCount == model.items.count)
        #expect(model.totals.selectedFiles == others + 2)
        #expect(model.totals.selectedFolders == 2)
        model.select(mask: "caf*.txt", select: false)
        #expect(model.selectionCount == model.items.count - 2)
        model.restoreSelection()
        #expect(model.selectionCount == model.items.count - 1)
        #expect(!model.isSelected(row: two))
    }

    /// Marks and the cursor stay on their own entry through another order, a filter, a fresh
    /// reading and a look back; a mark does not move to the other spelling when its entry goes.
    @Test(arguments: [0, 200])
    internal func theMarkStaysOnItsEntryWhenTheListChanges(others: Int) throws {
        let model = try panel(others: others)
        model.toggleSelection(row: try row(model, "\(decomposed).txt"))
        model.toggleSelection(row: try row(model, composed))
        model.moveCursor(to: try row(model, "\(decomposed).txt"))
        let right = [Array(composed.utf8), Array("\(decomposed).txt".utf8), Array("\(decomposed).txt".utf8)]
        #expect(marksAndCursor(model) == right)
        // Another order, a filter, a fresh reading, and a look back.
        model.setSort(ListOrder(key: .size, descending: true))
        #expect(marksAndCursor(model) == right)
        model.setSort(ListOrder())
        model.setFilter(PanelFilter(title: "caf") { $0.name.hasPrefix("caf") })
        #expect(marksAndCursor(model) == right)
        #expect(model.items.count == 4)
        model.setFilter(nil)
        let snapshot = model.snapshot()
        memory.addFile("/d/zz-new.txt")
        #expect(model.update(with: try listing("/d")))
        #expect(marksAndCursor(model) == right)
        #expect(model.items.count == others + 5)
        // The other spelling of a marked file goes away: its mark does not move over.
        try memory.remove(memory.url("/d/\(decomposed).txt"))
        model.update(with: try listing("/d"))
        #expect(model.selectionCount == 1)
        #expect(bytes(model.operands()) == [Array(composed.utf8)])
        #expect(!model.isSelected(row: try row(model, "\(composed).txt")))
        model.restore(snapshot)
        #expect(marksAndCursor(model) == right)
    }

    /// A calculated size goes to the folder of that spelling, by both routes, under a filter and
    /// through a fresh reading.
    @Test(arguments: [0, 200])
    internal func aCalculatedSizeGoesToItsOwnFolder(others: Int) throws {
        let model = try panel(others: others)
        let (one, two) = (try row(model, composed), try row(model, decomposed))
        model.toggleSelection(row: two)
        model.setComputedSizes([(name: composed, size: 100), (name: decomposed, size: 7)])
        #expect(model.item(atRow: one)?.computedSize == 100)
        #expect(model.item(atRow: two)?.computedSize == 7)
        #expect(model.totals.selectedBytes == 7)
        #expect(model.totals.totalBytes == 107 + 5 + Int64(others) * 7)
        // By one name alone, the folder written like it.
        model.setComputedSizes([(name: decomposed, size: 9)])
        #expect(model.item(atRow: one)?.computedSize == 100)
        #expect(model.item(atRow: two)?.computedSize == 9)
        #expect(model.totals.selectedBytes == 9)
        // Under a filter the sizes go to both lists, and a fresh reading carries each over to its own.
        model.setFilter(PanelFilter(title: "folders") { $0.isFolder })
        model.setComputedSizes([(name: composed, size: 1), (name: decomposed, size: 2)])
        #expect(Set(model.items.map(\.computedSize)) == [1, 2])
        #expect(model.items.count == 2)
        model.setFilter(nil)
        model.update(with: try listing("/d"))
        #expect(model.item(atRow: try row(model, composed))?.computedSize == 1)
        #expect(model.item(atRow: try row(model, decomposed))?.computedSize == 2)
        #expect(model.isSelected(row: try row(model, decomposed)))
        #expect(model.selectionCount == 1)
    }

    /// Where a name is single, either spelling still means the one entry, as before.
    @Test
    internal func aNameWrittenDifferentlyStillFindsTheOnlyEntryThatReadsTheSame() throws {
        memory.addFile("/single/\(composed).txt")
        for index in 0..<100 {
            memory.addFile("/single/f\(index)")
        }
        let model = PanelModel(directory: memory.url("/single"))
        model.show(try listing("/single"))
        // Asked often enough for the model to make its index of names on the way.
        for _ in 0..<4 {
            #expect(model.row(ofName: "\(decomposed).txt") == model.row(ofName: "\(composed).txt"))
        }
        model.setSelected(true, names: ["\(decomposed).txt"])
        #expect(model.selectionCount == 1)
        #expect(model.operands().map(\.name) == ["\(composed).txt"])
        #expect(model.selection.contains("\(decomposed).txt"))
        model.deselect(["\(decomposed).txt"])
        #expect(model.selectionCount == 0)
        model.setSelection(names: ["\(decomposed).txt", "f1", "missing"])
        #expect(model.selectionCount == 2)
        model.setSelected(false, names: ["\(decomposed).txt"])
        #expect(model.selection == ["f1"])
    }

    /// A folder with the two names as files (of two and three bytes) and as folders, among
    /// `others` plain files.
    private func panel(others: Int) throws -> PanelModel {
        memory.addFile("/d/\(composed).txt", "12")
        memory.addFile("/d/\(decomposed).txt", "123")
        memory.addDirectory("/d/\(composed)")
        memory.addDirectory("/d/\(decomposed)")
        for index in 0..<others {
            memory.addFile("/d/plain\(index).txt", "1234567")
        }
        let model = PanelModel(directory: memory.url("/d"))
        model.show(try listing("/d"))
        return model
    }

    /// The listing of `path` as a panel reads it.
    private func listing(_ path: String) throws -> Listing {
        try PanelLoader.load(memory.url(path), showHidden: false, fileSystems: fileSystems).listing
    }

    /// The names of `items` as their bytes, which tell the two spellings apart.
    private func bytes(_ items: [FileItem]) -> [[UInt8]] { items.map { Array($0.name.utf8) } }

    /// The row of the entry written exactly as `name`.
    private func row(_ model: PanelModel, _ name: String) throws -> Int {
        let index = try #require(model.items.firstIndex { Array($0.name.utf8) == Array(name.utf8) })
        return index + (model.hasParentRow ? 1 : 0)
    }

    /// The marked entries' names as bytes, then the cursor's, when exactly two are marked;
    /// otherwise nothing, so that a wrong count never compares equal.
    private func marksAndCursor(_ model: PanelModel) -> [[UInt8]] {
        guard model.selectionCount == 2, let cursor = model.cursorItem else {
            return []
        }
        return bytes(model.operands()) + [Array(cursor.name.utf8)]
    }
}

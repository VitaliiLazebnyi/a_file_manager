import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Whether a file is among a panel's operands (review 2, second pass, S011): answered from
/// memory, and the memory dropped whenever the marks or the cursor change it.
@MainActor
@Suite
internal struct OperandFileTests {
    private static let folder = URL(fileURLWithPath: "/review2/second")

    /// Two hundred folders and the files `only.txt` and `other.txt`.
    private static var items: [FileItem] {
        (0..<200).map { Fixture.folder("dir\($0)", in: folder) }
            + [Fixture.file("only.txt", in: folder), Fixture.file("other.txt", in: folder)]
    }

    /// Every way the marks change is seen: marking and unmarking by name, everything, the
    /// opposite, and without marks the cursor wherever it goes.
    @Test
    internal func whetherAFileIsMarkedIsAnsweredFromMemoryUntilTheMarksChange() throws {
        let model = Fixture.panel(Self.items, at: Self.folder)
        model.select { $0.isFolder }
        #expect(model.selectionCount == 200)
        #expect(!model.hasOperandFile)
        #expect(!model.hasOperandFile)
        // Every way the marks change is seen.
        model.setSelected(true, names: ["only.txt"])
        #expect(model.hasOperandFile)
        model.setSelected(false, names: ["only.txt"])
        #expect(!model.hasOperandFile)
        model.selectAll()
        #expect(model.hasOperandFile)
        model.invertSelection()
        #expect(!model.hasSelection)
        // Without marks the cursor decides, wherever it goes.
        model.moveCursor(to: try #require(model.row(ofName: "only.txt")))
        #expect(model.hasOperandFile)
        model.moveCursor(to: try #require(model.row(ofName: "dir3")))
        #expect(!model.hasOperandFile)
    }

    /// A fresh reading in which a marked folder became a file makes it a file operand; a filter
    /// that hides the only marked file takes its mark, and the answer with it.
    @Test
    internal func theAnswerFollowsAFreshReadingAndAFilter() {
        let model = Fixture.panel(Self.items, at: Self.folder)
        // A fresh reading in which a marked folder has become a file.
        model.select { $0.name == "dir5" }
        #expect(!model.hasOperandFile)
        var changed = Self.items
        changed[5] = Fixture.file("dir5", in: Self.folder)
        model.update(with: Fixture.listing(changed, at: Self.folder))
        #expect(model.isSelected(changed[5]))
        #expect(model.hasOperandFile)
        // A filter that hides the only marked file takes its mark, and the answer with it.
        model.clearSelection()
        model.setSelected(true, names: ["other.txt", "dir9"])
        #expect(model.hasOperandFile)
        model.setFilter(PanelFilter(title: "folders") { $0.isFolder })
        #expect(!model.hasOperandFile)
        #expect(model.selectionCount == 1)
    }
}

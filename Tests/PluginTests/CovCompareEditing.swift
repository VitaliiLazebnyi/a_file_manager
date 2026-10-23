import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import CompareContentPlugin

/// Resynchronizing, swapping, editing, undoing and saving a compare session without its window: the arms the
/// window's tests do not take.
@MainActor
@Suite
internal struct CovCompareEditing {
    /// A resync needs a line on both sides; one that crosses an earlier one, or shares a line with it, replaces it.
    @Test
    internal func aResyncReplacesTheResyncsItCrosses() throws {
        let stage = try CovCompareStage(left: "a\nb\nc\nd\n", right: "a\nx\nc\nd\ne\n")
        let session = stage.session(inline: true)
        let added = try #require((0..<session.rowCount).first { session.kind(ofRow: $0) == .added })
        session.resync(leftRow: added, rightRow: 0)
        session.resync(leftRow: 99, rightRow: 0)
        session.clearResync()
        #expect(session.anchors.isEmpty)
        for (left, right) in [(3, 0), (0, 3), (0, 1), (2, 1), (0, 1)] {
            session.resync(leftRow: try row(session, left: left), rightRow: try row(session, right: right))
            #expect(session.anchors.count == 1 && session.anchors.first?.left == left)
            #expect(session.anchors.first?.right == right)
        }
        session.swap()
        #expect(session.anchors.first?.left == 1 && session.anchors.first?.right == 0)
    }

    /// Swapping binary files swaps their sides and compares them again.
    @Test
    internal func binaryFilesAreSwapped() throws {
        let stage = try CovCompareStage(left: Data([0, 1]), right: Data([0, 1, 2]))
        let session = stage.session(inline: true)
        session.swap()
        guard case .binary(let left, let right, let diff) = session.content else {
            Issue.record("not binary")
            return
        }
        #expect(left == Data([0, 1, 2]) && right == Data([0, 1]) && diff.differingBytes == 1)
    }

    /// Only so many edits are kept for Undo; Undo does nothing outside edit mode.
    @Test
    internal func onlySoManyEditsAreUndone() throws {
        let stage = try CovCompareStage(left: "a\n", right: "b\n")
        let session = stage.session(inline: true)
        session.undo()
        session.setEditing(true)
        for number in 0...100 {
            session.setText("edit \(number)", .left, row: 0)
        }
        for _ in 0...100 {
            session.undo()
        }
        #expect(session.text(.left, row: 0) == "edit 0" && !session.canUndo)
    }

    /// A line is typed only where the row has one on that side.
    @Test
    internal func aLineIsTypedOnlyWhereThereIsOne() throws {
        let stage = try CovCompareStage(left: "a\n", right: "a\nb\n")
        let session = stage.session(inline: true)
        session.setEditing(true)
        session.setText("x", .left, row: 1)
        session.setText("x", .left, row: 9)
        #expect(!session.hasUnsavedChanges && session.text(.right, row: 1) == "b")
    }

    /// Lines copied into a file without line breaks take the other file's; lines copied where the target has none
    /// go in before its next line.
    @Test
    internal func copiedLinesTakeTheirPlaceAndLineBreaks() throws {
        let stage = try CovCompareStage(left: "x", right: "y\r\nz\r\n")
        let session = stage.session(inline: true)
        session.setEditing(true)
        session.copy(rows: 0..<2, to: .left)
        guard case .text(let left, _, _, _) = session.content else {
            Issue.record("not text")
            return
        }
        #expect(left.lines.map(\.text) == ["y", "z"] && left.lines.allSatisfy { $0.ending == .carriageReturnLineFeed })

        let middle = try CovCompareStage(left: "a\nb\nc\nd\n", right: "a\nd\n")
        let edited = middle.session(inline: true)
        edited.setEditing(true)
        // The rows of b and c have no line on the right: they go in before d.
        let removed = (0..<edited.rowCount).filter { edited.kind(ofRow: $0) == .removed }
        edited.copy(rows: try #require(removed.first)..<(try #require(removed.last) + 1), to: .right)
        guard case .text(_, let right, _, _) = edited.content else {
            Issue.record("not text")
            return
        }
        #expect(right.lines.map(\.text) == ["a", "b", "c", "d"])
    }

    /// Saving at once: nothing to save is done; a side without a file is left; a file changed meanwhile is reported.
    @Test
    internal func savingAtOnceReportsWhatIsNotSaved() throws {
        let stage = try CovCompareStage(left: "a\n", right: "b\n")
        let session = stage.session(inline: true)
        #expect(session.saveNow())
        session.setEditing(true)
        session.setText("edited", .left, row: 0)
        let file = session.leftURL
        session.leftURL = nil
        #expect(session.saveNow() && session.hasUnsavedChanges)
        session.leftURL = file
        try stage.put(Data("changed by someone else\n".utf8), at: "/A/left.txt")
        #expect(!session.saveNow())
        #expect(stage.bench.interaction.log.last == "inform: mem:/A/left.txt could not be saved.")
    }

    /// The row that shows line `left` of the left text.
    private func row(_ session: CompareSession, left: Int) throws -> Int {
        guard case .text(_, _, let diff, _) = session.content else {
            throw CocoaError(.featureUnsupported)
        }
        return try #require(diff.rows.firstIndex { $0.left == left })
    }

    /// The row that shows line `right` of the right text.
    private func row(_ session: CompareSession, right: Int) throws -> Int {
        guard case .text(_, _, let diff, _) = session.content else {
            throw CocoaError(.featureUnsupported)
        }
        return try #require(diff.rows.firstIndex { $0.right == right })
    }
}

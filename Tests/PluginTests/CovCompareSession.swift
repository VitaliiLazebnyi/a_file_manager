import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import CompareContentPlugin

/// A compare session without its window: what it shows when nothing is loaded, comparisons that are cancelled,
/// identical and binary files, and the rows asked about while a new comparison is still running.
@MainActor
@Suite
internal struct CovCompareSession {
    /// Nothing loaded: no rows, no texts, no search, and comparing again changes nothing.
    @Test
    internal func nothingLoadedShowsNothing() throws {
        let stage = try CovCompareStage(left: "a\n", right: "b\n")
        let session = CompareSession(kernel: stage.bench.kernel)
        session.runsInline = true
        session.recompute()
        #expect(session.phase == .empty && session.kind(ofRow: 0) == .equal && session.label(.left, row: 0).isEmpty)
        #expect(session.text(.left, row: 0) == nil && session.highlights(.left, row: 0).isEmpty)
        #expect(session.find("a", from: 0, forward: true) == nil)
        session.swap()
        #expect(session.phase == .empty)
    }

    /// A comparison of nothing loaded yet that is cancelled leaves the window empty.
    @Test
    internal func aCancelledFirstComparisonLeavesItEmpty() async throws {
        let stage = try CovCompareStage(left: "a\n", right: "b\n")
        let session = stage.session(inline: false)
        session.cancel()
        #expect(await CovCompareStage.settle { session.phase != .working })
        #expect(session.phase == .empty && session.status == "Cancelled")
    }

    /// A comparison that is cancelled while it runs in the background says the differences are incomplete.
    @Test
    internal func aCancelledRecomparisonSaysItIsIncomplete() async throws {
        let text = CovCompareStage.lines(2_500)
        let stage = try CovCompareStage(left: text, right: text + "more\n")
        let session = stage.session(inline: false)
        #expect(await CovCompareStage.settle { session.phase == .ready })
        session.recompute()
        session.cancel()
        #expect(await CovCompareStage.settle { session.phase == .ready })
        #expect(session.status == "Cancelled: the differences shown are incomplete")
    }

    /// Identical files that are not loaded say so; identical binary files too; one binary difference is one.
    @Test
    internal func identicalAndBinaryFilesSaySo() throws {
        let stage = try CovCompareStage(left: "same\n", right: "same\n")
        let session = CompareSession(kernel: stage.bench.kernel)
        session.runsInline = true
        session.limits = CompareLoader.Limits(quickCheckFrom: 1, loadLimit: 1_000)
        session.leftURL = stage.memory.url("/A/left.txt")
        session.rightURL = stage.memory.url("/B/right.txt")
        session.compare()
        #expect(session.isIdentical && session.status == "The two files have the same content!")
        let binary = try CovCompareStage(left: Data([0, 1, 2]), right: Data([0, 1, 2]))
        #expect(binary.session(inline: true).status == "The two files have the same content!")
        try binary.put(Data([0, 1, 3]), at: "/B/right.txt")
        let one = binary.session(inline: true)
        #expect(one.status.hasPrefix("1 difference, 1 bytes differ"))
        #expect(one.find("00", from: 0, forward: true) == 0)
        var changed = Data(repeating: 0, count: 48)
        (changed[0], changed[40]) = (1, 1)
        let two = try CovCompareStage(left: Data(repeating: 0, count: 48), right: changed)
        #expect(two.session(inline: true).status.hasPrefix("2 differences, 2 bytes differ"))
    }

    /// A width of bytes the choices do not have is remembered as the usual one.
    @Test
    internal func anOddWidthOfBytesIsRememberedAsTheUsualOne() throws {
        let stage = try CovCompareStage(left: Data([0, 1]), right: Data([0, 2]))
        let session = stage.session(inline: true)
        session.bytesPerLine = 12
        session.optionsChanged()
        let settings = stage.bench.kernel.settings.scoped(to: CompareSettingsKey.scope)
        #expect(settings.index(CompareSettingsKey.bytesPerLine, default: 9) == 1)
    }

    /// While the new comparison of a large text runs, the rows still describe the old texts: lines that are gone
    /// are no text, and a search does not find them.
    @Test
    internal func rowsOfTextsThatChangedMeanwhileAreNoText() async throws {
        let text = CovCompareStage.lines(2_500)
        let stage = try CovCompareStage(left: text + "only left\n", right: text)
        let session = stage.session(inline: false)
        #expect(await CovCompareStage.settle { session.phase == .ready })
        let last = session.rowCount - 1
        #expect(session.kind(ofRow: last) == .removed && session.kind(ofRow: last + 1) == .equal)
        #expect(session.text(.left, row: last + 1) == nil)
        session.setEditing(true)
        // The left lines of the first rows are replaced by none: the left text is shorter now.
        session.copy(rows: last..<(last + 1), to: .left)
        #expect(session.text(.left, row: last) == nil && session.label(.left, row: last).isEmpty)
        #expect(session.find("only left", from: 0, forward: true) == nil)
        #expect(await CovCompareStage.settle { session.phase == .ready })
    }

    /// A search finds nothing in empty files or for nothing, and gives up when it is cancelled.
    @Test
    internal func aSearchFindsNothingInEmptyFilesOrWhenCancelled() throws {
        let empty = try CovCompareStage(left: "", right: "")
        #expect(empty.session(inline: true).find("a", from: 0, forward: true) == nil)
        let stage = try CovCompareStage(left: CovCompareStage.lines(3_000), right: CovCompareStage.lines(3_000))
        let session = stage.session(inline: true)
        #expect(session.find("", from: 0, forward: true) == nil)
        let cancellation = CancellationFlag()
        cancellation.cancel()
        let found = CompareSession.search(
            session.content,
            "missing",
            from: 0,
            forward: true,
            cancellation: cancellation
        )
        #expect(found == nil)
    }

    /// Binary rows past the end of the shorter file have no text there, and a search skips them.
    @Test
    internal func binaryRowsPastTheShorterFileHaveNoText() throws {
        let stage = try CovCompareStage(left: Data(repeating: 1, count: 40), right: Data([1, 0]))
        let session = stage.session(inline: true)
        #expect(session.text(.right, row: 2) == nil && session.text(.left, row: 2) != nil)
        #expect(session.find("01 01 01", from: 0, forward: true) == 1)
        #expect(session.find("01 00", from: 0, forward: true) == 0)
    }

    /// A search away from the main thread answers the latest question only, and none for a session that is gone.
    @Test
    internal func aSearchAwayFromTheMainThreadAnswersTheLatestOnly() async throws {
        let stage = try CovCompareStage(left: "a\nb\n", right: "a\nc\n")
        let session = stage.session(inline: true)
        session.runsInline = false
        var answers: [String] = []
        session.find("b", from: 0, forward: true) { _ in answers.append("replaced") }
        session.find("c", from: 0, forward: true) { _ in answers.append("stale") }
        // Comparing again makes the search that runs stale.
        session.recompute()
        do {
            let gone = stage.session(inline: true)
            gone.runsInline = false
            gone.find("a", from: 0, forward: true) { _ in answers.append("gone") }
        }
        let other = stage.session(inline: true)
        other.runsInline = false
        other.find("c", from: 0, forward: true) { answers.append("found \($0 ?? -1)") }
        #expect(await CovCompareStage.settle { answers.contains("found 1") })
        #expect(answers == ["found 1"])
    }

    /// The parts that differ inside many changed lines are worked out again once too many are remembered.
    @Test
    internal func manyChangedLinesAreWorkedOutAgain() throws {
        let count = 4_200
        let left = (0..<count).map { "left \($0)\n" }.joined()
        let right = (0..<count).map { "right \($0)\n" }.joined()
        let session = try CovCompareStage(left: left, right: right).session(inline: true)
        let marked = (0..<count).filter { !session.highlights(.right, row: $0).isEmpty }
        #expect(marked.count == count && !session.highlights(.left, row: 0).isEmpty)
    }
}

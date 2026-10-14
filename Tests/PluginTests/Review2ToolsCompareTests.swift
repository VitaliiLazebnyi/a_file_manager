import AFMContracts
import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import CompareContentPlugin

private struct Seeded: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state ^ (state >> 29)
    }
}

private func isValid(_ segments: [DiffSegment], _ a: [Int], _ b: [Int]) -> Bool {
    var (i, j) = (0, 0)
    for segment in segments {
        guard segment.a.lowerBound == i, segment.b.lowerBound == j, !(segment.a.isEmpty && segment.b.isEmpty) else {
            return false
        }
        if segment.isEqual, Array(a[segment.a]) != Array(b[segment.b]) { return false }
        (i, j) = (segment.a.upperBound, segment.b.upperBound)
    }
    return i == a.count && j == b.count && Myers.apply(segments, to: a, from: b) == b
}

/// A source-like file: mostly distinct lines, some repeated ones (braces, blanks).
private func sourceLike(_ count: Int, seed: UInt64) -> [Int] {
    var random = Seeded(state: seed)
    return (0..<count).map { index in
        Int.random(in: 0..<10, using: &random) < 2 ? -Int.random(in: 1...30, using: &random) : index
    }
}

/// Review round 2: the diff of large files near the shortest, saving that never loses or mangles
/// a file, and a session that does not trust a diff that is out of date.
@Suite struct Review2CompareDiff {
    @Test func aDeletedBlockInALargeFileCostsAboutTheBlock() {
        let a = sourceLike(24_000, seed: 1)
        var b = a
        var random = Seeded(state: 2)
        b.removeSubrange(9_000..<10_500)
        for _ in 0..<150 {
            b[Int.random(in: 0..<b.count, using: &random)] = 1_000_000 + Int.random(in: 0..<1_000_000, using: &random)
        }
        let segments = Myers.diff(a, b)
        #expect(isValid(segments, a, b))
        // The shortest script deletes the block and replaces 150 lines: at most 1,500 + 2 x 150.
        #expect(Myers.editDistance(segments) <= 1_800 + 100)
    }

    @Test func aMovedBlockInALargeFileCostsAboutTwiceTheBlock() {
        let a = sourceLike(24_000, seed: 3)
        var b = a
        let block = Array(b[3_000..<3_400])
        b.removeSubrange(3_000..<3_400)
        b.insert(contentsOf: block, at: 17_000)
        var random = Seeded(state: 4)
        for _ in 0..<100 {
            b[Int.random(in: 0..<b.count, using: &random)] = 2_000_000 + Int.random(in: 0..<1_000_000, using: &random)
        }
        let segments = Myers.diff(a, b)
        #expect(isValid(segments, a, b))
        #expect(Myers.editDistance(segments) <= 1_000 + 100)
    }

    @Test func whenTheSearchIsCutOffLinesUniqueToBothSidesHoldTheDiffTogether() {
        // A low limit forces the cut-off at once; the lines that occur once on each side anchor the result.
        let a = Array(0..<6_000)
        var b = a
        b.removeSubrange(2_000..<2_800)
        var random = Seeded(state: 5)
        for _ in 0..<60 {
            b[Int.random(in: 0..<b.count, using: &random)] = 100_000 + Int.random(in: 0..<100_000, using: &random)
        }
        for limit in [0, 1, 5, 20] {
            let segments = Myers.diff(a, b, costLimit: limit)
            #expect(isValid(segments, a, b))
            #expect(Myers.editDistance(segments) <= 800 + 2 * 60 + 40)
        }
    }

    @Test func cutOffDiffsStayValidOnSmallRandomInputs() {
        var random = Seeded(state: 6)
        for _ in 0..<400 {
            let a = (0..<Int.random(in: 0...40, using: &random)).map { _ in Int.random(in: 0..<6, using: &random) }
            let b = (0..<Int.random(in: 0...40, using: &random)).map { _ in Int.random(in: 0..<6, using: &random) }
            for limit in [0, 1, 2, 3, 8] { #expect(isValid(Myers.diff(a, b, costLimit: limit), a, b)) }
        }
    }

    @Test func theLimitFollowsTheSizeAndStaysBounded() {
        #expect(Myers.defaultLimit(forSize: 19_999) == nil)
        #expect(Myers.defaultLimit(forSize: 20_000) == 8_192)
        #expect((Myers.defaultLimit(forSize: 100_000) ?? 0) > 2_000)
        #expect(Myers.defaultLimit(forSize: 10_000_000) == 256)
    }

    @Test func insideALineOnlyTheStartOfAHugeLineIsLookedAt() {
        let long = String(repeating: "abcdefghij", count: 200_000)
        let ranges = TextDiff.inline(long, long + "X")
        #expect(
            ranges.left.allSatisfy { $0.upperBound <= long.utf16.count }
                && ranges.right.last?.upperBound == long.utf16.count + 1)
    }
}

@MainActor @Suite struct Review2CompareSession {
    let box: Sandbox
    let plugin = CompareContentPlugin(opensWindows: false)
    let settings = MemorySettings()
    let bench: TestBench
    var ui: ScriptedInteraction { bench.ui }
    var session: CompareSession { plugin.sessions[0] }

    init() throws {
        box = try Sandbox()
        try box.file("A/f.txt", "one\ntwo\nthree\nfour\n")
        try box.file("B/f.txt", "one\n2\nthree\nfour\nfive\n")
        bench = TestBench(
            plugins: [plugin], fileSystems: [LocalFileSystem()], left: box.url("A"), right: box.url("B"),
            settings: settings)
    }

    func open() {
        bench.left.reload()
        bench.left.moveCursor(toName: "f.txt")
        bench.commands.perform(.compareByContent)
        session.setEditing(true)
    }

    @Test func undoPutsBackExactlyWhatEditsReplaced() {
        open()
        let before = session.text(.right, row: 1)
        session.copy(rows: 1..<2, to: .right)
        session.setText("FOUR!", .left, row: 3)
        session.copy(rows: 4..<5, to: .left)
        #expect(session.hasUnsavedChanges && session.canUndo)
        session.undo()
        session.undo()
        session.undo()
        #expect(!session.hasUnsavedChanges && !session.canUndo)
        #expect(
            session.text(.right, row: 1) == before
                && (0..<session.rowCount).map { session.text(.left, row: $0) } == ["one", "two", "three", "four", nil])
    }

    @Test func aRowThatPointsOutsideTheTextsIsNeverTrusted() {
        open()
        // Rows far beyond the texts change nothing and do not trap.
        session.copy(rows: 100..<200, to: .right)
        #expect(!session.hasUnsavedChanges)
    }

    @Test func quittingAsksAboutUnsavedEditsAndCanBeCalledOff() throws {
        open()
        session.setText("two edited", .left, row: 1)
        ui.choiceAnswers = [2]  // Cancel
        #expect(!plugin.shouldTerminate())
        #expect(box.read("A/f.txt") == "one\ntwo\nthree\nfour\n" && session.hasUnsavedChanges)
        ui.choiceAnswers = [1]  // Don't Save
        #expect(plugin.shouldTerminate())
        #expect(box.read("A/f.txt") == "one\ntwo\nthree\nfour\n" && !session.hasUnsavedChanges)
        session.setText("second edit", .left, row: 1)
        ui.choiceAnswers = [0]  // Save
        #expect(plugin.shouldTerminate())
        #expect(box.read("A/f.txt") == "one\nsecond edit\nthree\nfour\n")
    }

    @Test func stopAsksOnceMoreForWhatIsLeft() {
        open()
        session.setText("changed", .right, row: 1)
        ui.choiceAnswers = [0]
        plugin.stop()
        #expect(box.read("B/f.txt")?.contains("changed") == true)
    }

    @Test func aSaveNeverOverwritesAFileSomeoneElseChanged() throws {
        open()
        session.setText("mine", .left, row: 1)
        // Someone else writes the file after it was loaded.
        Thread.sleep(forTimeInterval: 0.02)
        try "theirs\n".write(to: box.url("A/f.txt"), atomically: true, encoding: .utf8)
        var saved: Bool?
        session.save { saved = $0 }
        #expect(saved == false && box.read("A/f.txt") == "theirs\n" && session.hasUnsavedChanges)
    }

    @Test func aCharacterTheEncodingCannotHoldIsRefusedNotTurnedIntoAQuestionMark() throws {
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: box.url("A/latin.txt"))
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0A, 0x78, 0x0A]).write(to: box.url("B/latin.txt"))
        bench.left.reload()
        bench.right.reload()
        bench.left.moveCursor(toName: "latin.txt")
        bench.commands.perform(.compareByContent)
        session.setEditing(true)
        session.setText("snowman \u{2603}", .left, row: 0)
        var saved: Bool?
        session.save { saved = $0 }
        #expect(saved == false)
        #expect(try Data(contentsOf: box.url("A/latin.txt")) == Data([0x63, 0x61, 0x66, 0xE9, 0x0A]))
    }

    @Test func theTwoSidesOfOneFileAreNotBothSaved() throws {
        try box.file("A/g.txt", "a\nb\n")
        bench.left.reload()
        bench.left.moveCursor(toName: "g.txt")
        bench.commands.perform(
            .compareByContent, .text(box.url("A/g.txt").absoluteString + "\n" + box.url("A/g.txt").absoluteString))
        session.setEditing(true)
        session.setText("x", .left, row: 0)
        session.setText("y", .right, row: 1)
        var saved: Bool?
        session.save { saved = $0 }
        #expect(saved == false && box.read("A/g.txt") == "a\nb\n")
    }

    @Test func replaceKeepsHardLinksTogetherAndRefusesAChangedFile() throws {
        let registry = FileSystemRegistry()
        registry.register(LocalFileSystem())
        try box.file("h/one.txt", "old")
        try FileManager.default.linkItem(at: box.url("h/one.txt"), to: box.url("h/two.txt"))
        try CompareLoader.replace(box.url("h/one.txt"), with: Data("new".utf8), fileSystems: registry)
        #expect(box.read("h/one.txt") == "new" && box.read("h/two.txt") == "new")
        let loaded = try #require(registry.item(at: box.url("h/one.txt")))
        try "changed elsewhere, longer".write(to: box.url("h/one.txt"), atomically: false, encoding: .utf8)
        #expect(throws: CompareLoader.SaveError.self) {
            try CompareLoader.replace(
                box.url("h/one.txt"), with: Data("mine".utf8), expected: loaded, fileSystems: registry)
        }
        #expect(box.read("h/one.txt") == "changed elsewhere, longer")
    }

    @Test func aFileThatCannotBeRenamedOverIsNotLostWhenTheSecondStepFails() throws {
        // A provider that cannot replace in one step: the old file is moved aside and comes back if the new one cannot be put in place.
        let memory = MemoryFileSystem()
        memory.addFile("/d/f.txt", "old")
        let registry = FileSystemRegistry()
        registry.register(memory)
        try CompareLoader.replace(memory.url("/d/f.txt"), with: Data("new".utf8), fileSystems: registry)
        #expect(memory.contents("/d/f.txt") == "new" && memory.allPaths.allSatisfy { !$0.contains("afm-") })
    }
}

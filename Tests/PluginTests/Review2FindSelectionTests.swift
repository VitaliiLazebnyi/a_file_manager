import AFMContracts
import AFMKernel
import AppKit
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import SelectionPlugin

/// Round 2 of the review, Selection: regular expressions that cannot hang, a `**` that is not
/// exponential, work off the main thread with a list-version guard, numbers that used to trap,
/// the ANSI file that used to raise.
@Suite struct Review2FindSelectionRules {
    func finishes(within seconds: Double = 60, _ work: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread {
            work()
            done.signal()
        }.start()
        return done.wait(timeout: .now() + seconds) == .success
    }

    @Test func aRegexMaskThatBacktracksEndsAndSaysSo() {
        let mask = SelectionMask("<(a+)+$")
        let name = String(repeating: "a", count: 45) + "!"
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var selected = [true]
        #expect(finishes { selected = mask.selected([MaskEntry(name: name)]) })
        #expect(selected == [false] && mask.timedOut)
        // The same mask judges a name it is quick on.
        let quick = SelectionMask("<(a+)+$")
        #expect(quick.selected([MaskEntry(name: "aaa")]) == [true] && !quick.timedOut)
    }

    @Test func aRegexMaskStopsWhenCancelled() {
        let mask = SelectionMask(#"<^(\w+[ _-]?)+\.jpg$"#)
        let flag = CancellationFlag()
        Thread {
            Thread.sleep(forTimeInterval: 0.05)
            flag.cancel()
        }.start()
        let entries = (0..<5).map { MaskEntry(name: String(repeating: "a", count: 40 + $0) + ".png") }
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var result: [Bool] = []
        #expect(finishes { result = mask.selected(entries, cancelled: { flag.isCancelled }) })
        #expect(result.allSatisfy { !$0 })
    }

    @Test func manyAnyLevelsInAPathMaskAreNotExponential() {
        let mask = SelectionMask("**/**/**/**/**/**/**/**/**/**/**/**/**/x.txt")
        let directory = (0..<30).map { "d\($0)" }
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var result = [true]
        #expect(finishes { result = mask.selected([MaskEntry(name: "y.txt", directory: directory)]) })
        #expect(result == [false])
        #expect(mask.selected([MaskEntry(name: "x.txt", directory: directory)]) == [true])
        // The chain still means what it did.
        #expect(
            SelectionMask("a/**/c/*.txt").selected([
                MaskEntry(name: "f.txt", directory: ["a", "c"]),
                MaskEntry(name: "f.txt", directory: ["a", "b", "b", "c"]),
                MaskEntry(name: "f.txt", directory: ["a", "b"]), MaskEntry(name: "f.txt", directory: ["x", "a", "c"])
            ]) == [true, true, false, true])
    }

    @Test func aNameAnsiCannotWriteDoesNotRaise() {
        let name = "\u{3000}\u{0300}"
        let item = FileItem(url: URL(fileURLWithPath: "/tmp/x"), name: name, isDirectory: false)
        let data = SelectionFile.encode(
            [item, FileItem(url: URL(fileURLWithPath: "/tmp/y"), name: "sél ą.txt", isDirectory: false)], as: .ansi)
        #expect(data.count == "??\r\nsél a.txt".unicodeScalars.count)
        #expect(data.contains(0xE9))
        #expect(SelectionFile.windows1252("plain") == Data("plain".utf8))
    }
}

@MainActor @Suite struct Review2FindSelectionCommands {
    typealias Ids = SelectionCommands

    let memory = MemoryFileSystem()
    private let scratch = ScratchPasteboard()
    var pasteboard: NSPasteboard { scratch.pasteboard }

    func makeBench(background: Bool) -> TestBench {
        TestBench(
            plugins: [SelectionPlugin(pasteboard: pasteboard, background: background)],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"), right: memory.url("/B"))
    }

    /// Gives the main run loop the time to hand the result of background work back.
    func settle(_ condition: () -> Bool) async {
        for _ in 0..<5_000 where !condition() { try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    @Test func aRegexMaskIsEvaluatedOffTheMainThread() async {
        memory.addFile("/A/alpha.txt")
        memory.addFile("/A/beta.txt")
        let bench = makeBench(background: true)
        bench.left.show(memory.url("/A"), focus: nil, history: .keep, completion: nil)
        bench.commands.perform(.selectGroup, .text("<^a"))
        // Nothing has happened yet: the mask is being worked out elsewhere.
        #expect(bench.left.model.selectionCount == 0)
        await settle { bench.left.model.selectionCount > 0 }
        #expect(bench.left.model.selection == ["alpha.txt"])
    }

    @Test func aMaskThatBacktracksIsReportedAndSelectsNothing() async {
        memory.addFile("/A/" + String(repeating: "a", count: 45) + "!")
        memory.addFile("/A/b")
        let bench = makeBench(background: true)
        bench.left.show(memory.url("/A"), focus: nil, history: .keep, completion: nil)
        bench.commands.perform(.selectGroup, .text("<(a+)+$"))
        await settle { bench.interaction.log.contains { $0.hasPrefix("inform:") } }
        #expect(
            bench.interaction.log.last == "inform: The regular expression takes too long."
                && bench.left.model.selectionCount == 0)
    }

    /// The list is read again before the answer comes back: the model refuses the rows made for the
    /// list it had, and the command is worked out again for the list as it is (see Review2PluginsA2Tests
    /// for a panel that went to another folder: that result is dropped).
    @Test func aResultForAnotherListIsWorkedOutAgain() async {
        memory.addFile("/A/alpha.txt")
        let bench = makeBench(background: true)
        bench.left.show(memory.url("/A"), focus: nil, history: .keep, completion: nil)
        bench.commands.perform(.selectGroup, .text("<alp"))
        memory.addFile("/A/alpine.txt")
        bench.left.show(memory.url("/A"), focus: nil, history: .keep, completion: nil)
        await settle { bench.left.model.selectionCount == 2 }
        #expect(bench.left.model.selection == ["alpha.txt", "alpine.txt"])
    }

    @Test func aLongListIsSelectedInvertedAndRestoredWithoutBlocking() async {
        for index in 0..<(Selections.longList + 5_000) { memory.addFile("/A/f\(index).txt") }
        memory.addFile("/A/keep.md")
        let bench = makeBench(background: true)
        let model = bench.left.model
        bench.left.show(memory.url("/A"), focus: nil, history: .keep, completion: nil)
        let total = model.items.count
        bench.commands.perform(.selectGroup, .text("*.txt"))
        #expect(model.selectionCount == 0)
        await settle { model.selectionCount == total - 1 }
        #expect(model.selectionCount == total - 1 && !model.selection.contains("keep.md"))
        bench.commands.perform(Ids.saveSelection)
        bench.commands.perform(.invertSelection)
        await settle { model.selection == ["keep.md"] }
        #expect(model.selection == ["keep.md"])
        bench.commands.perform(.restoreSelection)
        await settle { model.selectionCount == total - 1 }
        #expect(model.selectionCount == total - 1 && !model.selection.contains("keep.md"))
        bench.commands.perform(.unselectAll)
        bench.commands.perform(Ids.selectAllFiles)
        await settle { model.selectionCount == total }
        #expect(model.selectionCount == total)
    }

    @Test func comparingTwoFoldersAndTheClipboardWorkInTheBackground() async {
        memory.addFile("/A/only_left.txt")
        memory.addFile("/A/both.txt", "1")
        memory.addFile("/B/both.txt", "1")
        memory.addFile("/B/only_right.txt")
        let bench = makeBench(background: true)
        bench.commands.perform(Ids.compareDirectories)
        await settle { bench.left.model.selectionCount > 0 && bench.right.model.selectionCount > 0 }
        #expect(bench.left.model.selection == ["only_left.txt"] && bench.right.model.selection == ["only_right.txt"])
        bench.commands.perform(.unselectAll)
        pasteboard.clearContents()
        pasteboard.setString("both.txt\nmissing.txt\n", forType: .string)
        bench.commands.perform(Ids.loadSelectionFromClipboard)
        await settle { bench.left.model.selectionCount > 0 }
        #expect(bench.left.model.selection == ["both.txt"])
    }

    @Test func extremeCountsDoNotTrap() {
        memory.addFile("/A/a.txt")
        memory.addFile("/A/b.txt")
        let bench = makeBench(background: false)
        for count in [Int.min, Int.max, -1, 1 << 40] {
            bench.commands.perform(Ids.select, .index(count))
            bench.commands.perform(Ids.unselect, .index(count))
            bench.commands.perform(Ids.selectAllFiles, .index(count))
        }
        #expect(bench.left.model.rowCount > 0)
    }

    @Test func savingOverAFileKeepsNoTemporaryFileAndReplacesTheOldOne() {
        memory.addFile("/A/one.txt")
        memory.addFile("/B/list.txt", "old")
        let bench = makeBench(background: false)
        bench.left.moveCursor(toName: "one.txt")
        bench.interaction.choiceAnswers = [0]
        bench.commands.perform(Ids.saveSelectionToFileANSI, .location(memory.url("/B/list.txt")))
        #expect(memory.contents("/B/list.txt") == "one.txt")
        #expect(memory.allPaths.filter { $0.hasPrefix("/B/") } == ["/B/list.txt"])
    }
}

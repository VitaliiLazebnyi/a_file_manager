import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import SelectionPlugin

/// Round 2 of the review, Selection: regular expressions that cannot hang, a `**` that is not
/// exponential, work off the main thread with a list-version guard, numbers that used to trap,
/// the ANSI file that used to raise.
@Suite
internal struct Review2FindSelectionRules {
    /// Runs `work` on another thread and fails instead of hanging if it does not end within `Wait.ceiling`.
    internal func finishes(_ work: @escaping @Sendable () -> Void) -> Bool {
        let seconds = Wait.ceiling
        let done = DispatchSemaphore(value: 0)
        Thread {
            work()
            done.signal()
        }
        .start()
        return done.wait(timeout: .now() + seconds) == .success
    }

    /// A regular expression that backtracks without end is stopped, selects nothing and says so.
    @Test
    internal func aRegexMaskThatBacktracksEndsAndSaysSo() {
        let mask = SelectionMask("<(a+)+$")
        let name = String(repeating: "a", count: 45) + "!"
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var selected = [true]
        #expect(finishes { selected = mask.selected([MaskEntry(name: name)]) { false } })
        #expect(selected == [false] && mask.timedOut)
        // The same mask judges a name it is quick on.
        let quick = SelectionMask("<(a+)+$")
        #expect(quick.selected([MaskEntry(name: "aaa")]) { false } == [true] && !quick.timedOut)
    }

    /// A regular expression at work stops when the work is cancelled.
    @Test
    internal func aRegexMaskStopsWhenCancelled() {
        let mask = SelectionMask(#"<^(\w+[ _-]?)+\.jpg$"#)
        let flag = CancellationFlag()
        Thread {
            Thread.sleep(forTimeInterval: 0.05)
            flag.cancel()
        }
        .start()
        let entries = (0..<5).map { MaskEntry(name: String(repeating: "a", count: 40 + $0) + ".png") }
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var result: [Bool] = []
        #expect(finishes { result = mask.selected(entries) { flag.isCancelled } })
        #expect(result.allSatisfy { !$0 })
    }

    /// Many `**` in a path mask take linear time and keep their meaning.
    @Test
    internal func manyAnyLevelsInAPathMaskAreNotExponential() {
        let mask = SelectionMask("**/**/**/**/**/**/**/**/**/**/**/**/**/x.txt")
        let directory = (0..<30).map { "d\($0)" }
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var result = [true]
        #expect(finishes { result = mask.selected([MaskEntry(name: "y.txt", directory: directory)]) { false } })
        #expect(result == [false])
        #expect(mask.selected([MaskEntry(name: "x.txt", directory: directory)]) { false } == [true])
        // The chain still means what it did.
        #expect(
            SelectionMask("a/**/c/*.txt")
                .selected([
                    MaskEntry(name: "f.txt", directory: ["a", "c"]),
                    MaskEntry(name: "f.txt", directory: ["a", "b", "b", "c"]),
                    MaskEntry(name: "f.txt", directory: ["a", "b"]),
                    MaskEntry(name: "f.txt", directory: ["x", "a", "c"])
                ]) { false } == [true, true, false, true]
        )
    }

    /// A name the Windows code page cannot write is saved with question marks, not refused.
    @Test
    internal func aNameAnsiCannotWriteDoesNotRaise() {
        let name = "\u{3000}\u{0300}"
        let item = FileItem(url: URL(fileURLWithPath: "/tmp/x"), name: name)
        let data = SelectionFile.encode(
            [item, FileItem(url: URL(fileURLWithPath: "/tmp/y"), name: "sél ą.txt")],
            as: .ansi
        )
        #expect(data.count == "??\r\nsél a.txt".unicodeScalars.count)
        #expect(data.contains(0xE9))
        #expect(SelectionFile.windows1252("plain") == Data("plain".utf8))
    }
}

import AFMKernel
import Foundation
import Testing

@testable import MultiRenamePlugin

/// The wildcard matcher and the planner at their edges.
extension CoverageRenameEngine {
    /// Counts the calls of a closure.
    ///
    /// Unchecked: the count is guarded by `lock`.
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        /// How often `next` was called.
        var value: Int { lock.withLock { count } }

        /// Counts one more call and returns the count.
        func next() -> Int {
            lock.withLock {
                count += 1
                return count
            }
        }

        deinit {
            // Nothing to release.
        }
    }

    // MARK: The wildcard matcher

    /// A letter whose lower case is two letters stays itself.
    @Test
    internal func aLetterThatFoldsIntoTwoStaysItself() {
        #expect(WildcardMatcher.folded("\u{130}") == 0x130)
        #expect(WildcardMatcher.folded("Ä") == ("ä" as Unicode.Scalar).value)
    }

    /// An empty search matches nothing.
    @Test
    internal func anEmptySearchMatchesNothing() {
        #expect(WildcardMatcher("", caseSensitive: false).matches(in: "abc", firstOnly: false).isEmpty)
    }

    /// A long search finds the whole run, and gives up when it is cancelled.
    @Test
    internal func aLongSearchLooksAtTheCancellation() {
        let long = String(repeating: "a", count: 9_000) + "b"
        #expect(WildcardMatcher("*ab", caseSensitive: true).matches(in: long, firstOnly: true).first?.length == 9_001)
        let matcher = WildcardMatcher("a*b", caseSensitive: true)
        #expect(matcher.matches(in: long, firstOnly: true, guardian: RenameRegexGuard()) { true } == .gaveUp)
    }

    // MARK: The planner

    /// The local location of `path`.
    internal func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    /// A number does not fit beside a very long extension: the base gives way.
    @Test
    internal func aNumberDoesNotFitBesideAVeryLongExtension() {
        let ext = String(repeating: "e", count: 254)
        let numbered = RenamePlanner.numbered(url("/d/a." + ext), 2, isFolder: false)
        #expect(numbered.lastPathComponent == " (2)." + ext)
    }

    /// An item that waits for a skipped one is skipped too.
    @Test
    internal func anItemWaitingForASkippedOneIsSkippedToo() {
        let planner = RenamePlanner()
        // b and c want x and stay; a wants b's name, which stays taken, and stays too.
        let sources = [url("/d/a"), url("/d/b"), url("/d/c")]
        let targets: [URL?] = [url("/d/b"), url("/d/x"), url("/d/x")]
        let skipped = planner.skippingConflicts(
            sources: sources,
            targets: targets,
            existing: Set(sources.map(planner.key))
        )
        #expect(skipped.allSatisfy { $0 == nil })
    }

    /// Folders with nothing of the list inside keep the order of the list.
    @Test
    internal func foldersWithNothingOfTheListInsideKeepTheOrder() {
        let planner = RenamePlanner()
        let steps = planner.steps(
            sources: [url("/d/folder"), url("/e/file")],
            targets: [url("/d/folder2"), url("/e/file2")],
            isFolder: [true, false],
            temporaryName: nil
        ) { false }
        #expect(steps.map(\.item) == [0, 1])
    }

    /// A plan cancelled while the folders are put in order is cut short.
    @Test
    internal func aPlanCancelledWhileFoldersAreOrderedIsCutShort() {
        let planner = RenamePlanner()
        let asked = CallCounter()
        let steps = planner.steps(
            sources: [url("/d/folder"), url("/d/folder/file")],
            targets: [url("/d/other"), url("/d/folder/file2")],
            isFolder: [true, false],
            temporaryName: nil
        ) { asked.next() > 1 }
        #expect(steps.isEmpty && asked.value >= 2)
    }
}

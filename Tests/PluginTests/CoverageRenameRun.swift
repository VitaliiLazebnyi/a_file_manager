import AFMKernel
import Foundation
import ImageIO
import LocalFileSystemPlugin
import TestSupport
import Testing
import UniformTypeIdentifiers

@testable import MultiRenamePlugin

/// The parts of a rename run below the session: the runner that moves the files, the survey of
/// the folders, the dates inside pictures and the result log, where things go wrong.
@Suite
internal struct CoverageRenameRun {
    /// Counts the questions asked of a closure.
    ///
    /// Unchecked: the count is guarded by `lock`.
    internal final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        /// Counts one more question and returns the count.
        internal func next() -> Int {
            lock.withLock {
                count += 1
                return count
            }
        }

        deinit {
            // Nothing to release.
        }
    }

    /// A file system over memory that refuses chosen moves.
    internal let fileSystem = CoverageRenameFileSystem()
    /// `fileSystem` and the local disk.
    internal let registry = FileSystemRegistry()
    /// A folder of the test's own on the local disk.
    internal let box: Sandbox

    /// The file systems, and a sandbox on the disk.
    internal init() throws {
        box = try Sandbox()
        registry.register(fileSystem)
        registry.register(LocalFileSystem())
    }

    /// The location of `path` in `fileSystem`.
    internal func url(_ path: String) -> URL { fileSystem.url(path) }

    /// The steps of a plan for these renames, run to the end.
    internal func run(_ renames: [(String, String)]) -> RenameRunResult {
        run(renames, cancellation: CancellationFlag(), onProgress: nil)
    }

    /// The steps of a plan for these renames, run until `cancellation` says so; `onProgress` hears each step.
    internal func run(
        _ renames: [(String, String)],
        cancellation: CancellationFlag,
        onProgress: ((RenameStep, Int) -> Void)?
    ) -> RenameRunResult {
        let sources = renames.map { url($0.0) }
        let steps = RenamePlanner()
            .steps(sources: sources, targets: renames.map { url($0.1) }, isFolder: [], temporaryName: nil) { false }
        let runner = RenameRunner(fileSystems: registry, cancellation: cancellation)
        runner.onProgress = onProgress
        return runner.run(steps, sources: sources)
    }

    // MARK: The runner

    /// A cancelled run stops before its next step: nothing is renamed.
    @Test
    internal func aCancelledRunStopsBeforeTheNextStep() {
        fileSystem.base.addFile("/d/a")
        let cancellation = CancellationFlag()
        cancellation.cancel()
        let result = run([("/d/a", "/d/b")], cancellation: cancellation, onProgress: nil)
        #expect(result.cancelled && result.renamed.isEmpty && fileSystem.base.allPaths == ["/d", "/d/a"])
    }

    /// A ring of two, cancelled once the first is parked under a temporary name: its new name
    /// is still taken, so it comes back to its own.
    @Test
    internal func aParkedItemWhoseTurnNeverCameComesBack() {
        fileSystem.base.addFile("/d/1", "one")
        fileSystem.base.addFile("/d/2", "two")
        let cancellation = CancellationFlag()
        let result = run([("/d/1", "/d/2"), ("/d/2", "/d/1")], cancellation: cancellation) { step, _ in
            if step.kind == .park { cancellation.cancel() }
        }
        #expect(result.cancelled && result.renamed.isEmpty && result.failures.isEmpty)
        #expect(fileSystem.base.contents("/d/1") == "one" && fileSystem.base.contents("/d/2") == "two")
        #expect(fileSystem.base.allPaths == ["/d", "/d/1", "/d/2"])
    }

    /// The second of a ring cannot take the first one's name, so the first cannot go on, and it
    /// cannot come back either: it stays under the temporary name, and the user is told which.
    @Test
    internal func aParkedItemThatCannotComeBackIsReported() throws {
        fileSystem.base.addFile("/d/1", "one")
        fileSystem.base.addFile("/d/2", "two")
        fileSystem.refusedTargets = ["/d/1"]
        let result = run([("/d/1", "/d/2"), ("/d/2", "/d/1")])
        #expect(result.renamed.isEmpty && Set(result.failures.map(\.item)) == [0, 1])
        let left = try #require(result.failures.last)
        #expect(left.message.hasPrefix("The file was left under the temporary name .afm-rename-"))
        #expect(fileSystem.base.allPaths.contains { $0.hasPrefix("/d/.afm-rename-") })
    }

    /// A run cancelled after the second item moved: the parked first item still goes on to its
    /// new name, which is free by then.
    @Test
    internal func aParkedItemGoesOnWhenItsNameIsFree() {
        fileSystem.base.addFile("/d/1", "one")
        fileSystem.base.addFile("/d/2", "two")
        let cancellation = CancellationFlag()
        let result = run([("/d/1", "/d/2"), ("/d/2", "/d/1")], cancellation: cancellation) { step, _ in
            if step.kind == .direct { cancellation.cancel() }
        }
        #expect(result.cancelled && result.renamed.count == 2 && result.failures.isEmpty)
        #expect(fileSystem.base.contents("/d/1") == "two" && fileSystem.base.contents("/d/2") == "one")
    }

    /// The first of a ring cannot be parked: neither of the two moves, and the first is not
    /// tried again.
    @Test
    internal func anItemThatCannotBeParkedStays() {
        fileSystem.base.addFile("/d/1", "one")
        fileSystem.base.addFile("/d/2", "two")
        fileSystem.refusesTemporaryNames = true
        let result = run([("/d/1", "/d/2"), ("/d/2", "/d/1")])
        #expect(result.renamed.isEmpty && result.failures.map(\.item).sorted() == [0, 1])
        #expect(fileSystem.base.contents("/d/1") == "one" && fileSystem.base.allPaths == ["/d", "/d/1", "/d/2"])
    }

    /// Two rings that both fail leave two items parked; each is reported, in list order.
    @Test
    internal func twoParkedItemsAreReportedInOrder() {
        for name in ["1", "2", "3", "4"] {
            fileSystem.base.addFile("/d/" + name, name)
        }
        fileSystem.refusedTargets = ["/d/1", "/d/3"]
        let result = run([("/d/1", "/d/2"), ("/d/2", "/d/1"), ("/d/3", "/d/4"), ("/d/4", "/d/3")])
        let left = result.failures.filter { $0.message.hasPrefix("The file was left under") }.map(\.item)
        #expect(left == [0, 2])
    }

    /// A name that differs in its accents only goes by way of a temporary name; when the second
    /// half fails, the file is put back under its old name.
    @Test
    internal func aRenameOfTheAccentsAloneThatFailsIsUndone() {
        let decomposed = "e\u{301}.txt"
        let precomposed = "\u{E9}.txt"
        fileSystem.base.addFile("/d/" + decomposed)
        fileSystem.refusedTargets = ["/d/" + precomposed]
        let source = url("/d/" + decomposed)
        let target = url("/d/").appending(path: precomposed)
        let runner = RenameRunner(fileSystems: registry, cancellation: CancellationFlag())
        let result = runner.run(
            [RenameStep(item: 0, from: source, destination: target, kind: .direct, ontoItself: false)],
            sources: [source]
        )
        #expect(result.failures.count == 1 && result.renamed.isEmpty)
        #expect(fileSystem.base.allPaths == ["/d", "/d/" + decomposed])
    }

    // MARK: Searches that take too long

    /// A wildcard search over a very long name runs out of its time: the name gets no new name,
    /// and after three such names the search is given up.
    @Test
    internal func aWildcardSearchThatTakesTooLongIsGivenUp() throws {
        let long = String(repeating: "a", count: 20_000)
        let matcher = WildcardMatcher("a*a*a*a*b", caseSensitive: true)
        let guardian = RenameRegexGuard()
        for _ in 0..<3 {
            #expect(matcher.matches(in: long, firstOnly: false, guardian: guardian) { false } == .gaveUp)
        }
        #expect(guardian.isTripped)
        var settings = RenameSettings()
        settings.search = "a*a*a*a*b"
        let replace = try SearchReplace(settings)
        #expect(replace.apply(to: long) == long && replace.timedOut)
    }

    /// Cancelled in the middle of a name, the search answers nothing and counts no timeout.
    @Test
    internal func aWildcardSearchCancelledMidwayCountsNoTimeout() {
        let long = String(repeating: "a", count: 20_000)
        let guardian = RenameRegexGuard()
        let asked = Asked()
        let found = WildcardMatcher("a*a*b", caseSensitive: true)
            .matches(in: long, firstOnly: false, guardian: guardian) { asked.next() > 1 }
        #expect(found == .gaveUp && !guardian.hasTimedOut)
    }

    // MARK: Telling files apart

    /// Locations off the disk are taken at the planner's word: they are one file.
    @Test
    internal func locationsOffTheDiskAreTakenAtTheirWord() {
        #expect(RenameRunner.isSameFile(url("/d/a"), url("/d/A")))
    }

    /// A source or a target that is gone is no same file; a second spelling on the disk is.
    @Test
    internal func aSourceThatIsGoneIsNoSameFile() throws {
        let present = try box.file("present")
        #expect(!RenameRunner.isSameFile(box.url("gone"), present))
        #expect(!RenameRunner.isSameFile(present, box.url("gone")))
        #expect(RenameRunner.isSameFile(present, box.url("PRESENT")))
    }
}

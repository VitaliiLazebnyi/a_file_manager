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
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        /// Counts one more question and returns the count.
        func next() -> Int {
            lock.withLock {
                count += 1
                return count
            }
        }
    }

    internal let fileSystem = CoverageRenameFileSystem()
    internal let registry = FileSystemRegistry()
    internal let box: Sandbox

    internal init() throws {
        box = try Sandbox()
        registry.register(fileSystem)
        registry.register(LocalFileSystem())
    }

    internal func url(_ path: String) -> URL { fileSystem.url(path) }

    /// The steps of a plan for these renames, run.
    internal func run(
        _ renames: [(String, String)],
        cancellation: CancellationFlag = CancellationFlag(),
        onProgress: ((RenameStep, Int) -> Void)? = nil
    ) -> RenameRunResult {
        let sources = renames.map { url($0.0) }
        let steps = RenamePlanner()
            .steps(sources: sources, targets: renames.map { url($0.1) }, isFolder: [], temporaryName: nil) { false }
        let runner = RenameRunner(fileSystems: registry, cancellation: cancellation)
        runner.onProgress = onProgress
        return runner.run(steps, sources: sources)
    }

    // MARK: The runner

    @Test
    internal func aCancelledRunStopsBeforeTheNextStep() {
        fileSystem.base.addFile("/d/a")
        let cancellation = CancellationFlag()
        cancellation.cancel()
        let result = run([("/d/a", "/d/b")], cancellation: cancellation)
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
        for name in ["1", "2", "3", "4"] { fileSystem.base.addFile("/d/" + name, name) }
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

    // MARK: Telling files apart

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

    @Test
    internal func locationsOffTheDiskAreTakenAtTheirWord() {
        #expect(RenameRunner.isSameFile(url("/d/a"), url("/d/A")))
    }

    @Test
    internal func aSourceThatIsGoneIsNoSameFile() throws {
        let present = try box.file("present")
        #expect(!RenameRunner.isSameFile(box.url("gone"), present))
        #expect(!RenameRunner.isSameFile(present, box.url("gone")))
        #expect(RenameRunner.isSameFile(present, box.url("PRESENT")))
    }

    // MARK: Letter case

    /// A name in capitals is tried in small letters.
    @Test
    internal func aNameInCapitalsIsTriedInSmallLetters() throws {
        let file = try box.file("README")
        let item = try #require(registry.item(at: file))
        #expect(RenameSurvey(fileSystems: registry).foldsCase([item]))
    }

    @Test
    internal func aCancelledSurveyFoldsNothing() throws {
        let file = try box.file("notes.txt")
        let item = try #require(registry.item(at: file))
        let cancellation = CancellationFlag()
        cancellation.cancel()
        #expect(!RenameSurvey(fileSystems: registry, cancellation: cancellation).foldsCase([item]))
    }

    /// Off the local disk the folder is listed: a server that finds `NOTES.TXT` for `notes.txt`
    /// folds letter case, unless it holds both spellings.
    @Test
    internal func aServerIsAskedByListingTheFolder() throws {
        fileSystem.foldsCase = true
        fileSystem.base.addFile("/s/notes.txt", "abc")
        let item = try #require(registry.item(at: url("/s/notes.txt")))
        #expect(RenameSurvey(fileSystems: registry).foldsCase([item]))
        #expect(RenameSurvey(fileSystems: registry, cancellation: CancellationFlag()).foldsCase([item]))
        fileSystem.foldsCase = false
        fileSystem.base.addFile("/s/NOTES.TXT", "other")
        #expect(!RenameSurvey(fileSystems: registry).foldsCase([item]))
        #expect(!RenameSurvey(fileSystems: registry, cancellation: CancellationFlag()).foldsCase([item]))
    }

    /// A file with a second name (a hard link) is asked by listing its folder too.
    @Test
    internal func aFileWithTwoNamesIsAskedByListing() throws {
        let file = try box.file("linked.txt")
        try FileManager.default.linkItem(at: file, to: box.url("other.txt"))
        let item = try #require(registry.item(at: file))
        #expect(RenameSurvey(fileSystems: registry).foldsCase([item]))
    }

    @Test
    internal func theVolumeAnswersForFoldersAwayFromTheList() {
        #expect(RenameSurvey.volumeCaseFolding(url("/x")) == nil)
        let missing = box.url("not/there/yet")
        #expect(RenameSurvey.volumeCaseFolding(missing) == RenameSurvey.volumeCaseFolding(box.root))
        #expect(RenameSurvey.volumeCaseFolding(box.root) != nil)
    }

    @Test
    internal func noFoldersHoldNothing() {
        let keys = RenameSurvey(fileSystems: registry)
            .existingKeys(
                in: [:],
                planner: RenamePlanner(),
                isCancelled: { false }
            )
        #expect(keys.isEmpty)
    }

    /// A list of items on the local disk and on a server that tells the cases apart: only the
    /// folder on the disk folds them.
    @Test
    internal func eachFolderIsJudgedOnItsOwn() throws {
        let local = try box.file("a.txt")
        let remote = fileSystem.base.addFile("/r/b.txt")
        let entries = try [local, remote].map { RenameEntry(try #require(registry.item(at: $0))) }
        var settings = RenameSettings()
        settings.nameMask = "X[N]"
        let preview = RenameComputation.preview(
            RenameRequest(entries: entries, settings: settings, context: RenameContext()),
            fileSystems: registry,
            cache: RenameCache(),
            cancellation: nil
        ) { false }
        #expect(preview.planner.key(box.url("A.TXT")) == preview.planner.key(box.url("a.txt")))
        #expect(preview.planner.key(url("/r/B.TXT")) != preview.planner.key(url("/r/b.txt")))
    }

    /// A name given with a slash in front moves the item from the top of its file system; the
    /// folder it goes to is not near any of the list, and its volume is asked.
    @Test
    internal func aNameFromTheTopGoesElsewhere() throws {
        let file = try box.file("a/one.txt")
        let entry = RenameEntry(try #require(registry.item(at: file)))
        let target = RenameComputation.target(of: entry, named: box.url("b/two.txt").path)
        #expect(target.path == box.url("b/two.txt").path)
        let preview = RenameComputation.preview(
            RenameRequest(
                entries: [entry],
                settings: RenameSettings(),
                context: RenameContext(),
                given: [box.url("b/two.txt").path]
            ),
            fileSystems: registry,
            cache: RenameCache(),
            cancellation: nil
        ) { false }
        #expect(preview.statuses == [.ready] && preview.targets.first??.lastPathComponent == "two.txt")
        let remote = RenameEntry(try #require(registry.item(at: fileSystem.base.addFile("/r/s/x.txt"))))
        #expect(RenameComputation.target(of: remote, named: "/t/y.txt") == url("/t/y.txt"))
    }

    /// Accents written another way on the local disk: the name is put into the folder as typed.
    @Test
    internal func accentsWrittenAnotherWayKeepTheirForm() throws {
        let file = try box.file("e\u{301}.txt")
        let entry = RenameEntry(FileItem(url: file, name: "e\u{301}.txt"))
        let target = RenameComputation.target(of: entry, named: "\u{E9}.txt")
        #expect(target.lastPathComponent.unicodeScalars.count == 5)
    }

    /// A preview that is cancelled once the planner is made does not list the folders.
    @Test
    internal func aPreviewCancelledAfterThePlannerListsNothing() {
        fileSystem.base.addFile("/p/a.txt")
        fileSystem.base.addFile("/p/b.txt")
        let entries = ["/p/a.txt"].compactMap { registry.item(at: url($0)) }.map(RenameEntry.init)
        var settings = RenameSettings()
        settings.nameMask = "b"
        let asked = Asked()
        let preview = RenameComputation.preview(
            RenameRequest(entries: entries, settings: settings, context: RenameContext()),
            fileSystems: registry,
            cache: RenameCache(),
            cancellation: nil
        ) { asked.next() >= 3 }
        // Not compared with b.txt, which is there: the conflict is not found.
        #expect(preview.statuses == [.ready] && preview.existing.isEmpty)
    }

    /// A listing that is cut short by the cancellation counts for nothing.
    @Test
    internal func aListingCutShortHoldsNothing() {
        fileSystem.base.addFile("/q/a.txt")
        let cancellation = CancellationFlag()
        let keys = RenameSurvey(fileSystems: registry, cancellation: cancellation)
            .existingKeys(
                in: ["q": url("/q/")],
                planner: RenamePlanner(),
                isCancelled: {
                    cancellation.cancel()
                    return false
                }
            )
        #expect(keys.isEmpty)
    }

    // MARK: Dates in pictures

    /// A picture with the given EXIF and TIFF dates.
    internal func picture(_ name: String, exif: [CFString: Any]? = nil, tiff: [CFString: Any]? = nil) throws -> URL {
        let url = box.url(name)
        let context = try #require(
            CGContext(
                data: nil,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(
                url as CFURL,
                (url.pathExtension == "tif" ? UTType.tiff : UTType.jpeg).identifier as CFString,
                1,
                nil
            )
        )
        var properties: [CFString: Any] = [:]
        if let exif { properties[kCGImagePropertyExifDictionary] = exif }
        if let tiff { properties[kCGImagePropertyTIFFDictionary] = tiff }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    internal func taken(_ url: URL) -> String? {
        ContentDate.read(url)
            .map {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = .current
                let parts = calendar.dateComponents([.year, .month, .day, .hour], from: $0)
                return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0) \(parts.hour ?? 0)"
            }
    }

    @Test
    internal func theDateTakenComesFromTheBestField() throws {
        let original = try picture("o.jpg", exif: [kCGImagePropertyExifDateTimeOriginal: "2021:05:06 07:08:09"])
        #expect(taken(original) == "2021-5-6 7")
        let digitized = try picture("d.jpg", exif: [kCGImagePropertyExifDateTimeDigitized: "2020:01:02 03:04:05"])
        #expect(taken(digitized) == "2020-1-2 3")
        let plain = try picture("t.tif", tiff: [kCGImagePropertyTIFFDateTime: "2019:12:31 23:00:00"])
        #expect(taken(plain) == "2019-12-31 23")
        #expect(taken(try picture("n.jpg")) == nil)
    }

    @Test
    internal func onlyPlainPicturesOnTheDiskAreOpened() throws {
        #expect(ContentDate.read(url("/x.jpg")) == nil)
        #expect(ContentDate.read(try box.file("notes.txt")) == nil)
        #expect(ContentDate.read(try box.file("noextension")) == nil)
        #expect(ContentDate.read(try box.folder("folder.jpg")) == nil)
        #expect(ContentDate.read(try box.file("broken.jpg", "no picture")) == nil)
        #expect(ContentDate.isPicture(URL(fileURLWithPath: "/a/raw.dng")))
        #expect(!ContentDate.isPicture(URL(fileURLWithPath: "/a/x.unknownextension")))
    }

    /// `[T4]` reads each picture once, however often the preview is made.
    @Test
    internal func theDateTakenIsReadOnce() throws {
        let file = try picture("p.jpg", exif: [kCGImagePropertyExifDateTimeOriginal: "2021:05:06 07:08:09"])
        let cache = RenameCache()
        #expect(cache.contentDate(of: file) != nil)
        try FileManager.default.removeItem(at: file)
        #expect(cache.contentDate(of: file) != nil)
        #expect(cache.forChangedOrder().contentDate(of: file) != nil)
        #expect(RenameCache().contentDate(of: file) == nil)
    }

    // MARK: The result log

    @Test
    internal func aLogThatCannotBeWrittenIsLeftOut() throws {
        let folder = try box.folder("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        let log = folder.appending(path: RenameLog.fileName)
        RenameLog.write([RenamedItem(from: url("/a"), destination: url("/b"))], to: log, fileSystems: registry)
        #expect(!FileManager.default.fileExists(atPath: log.path))
    }

    @Test
    internal func aFileMovedElsewhereIsLoggedWithItsWholePath() {
        let text = RenameLog.text([RenamedItem(from: url("/a/x.txt"), destination: url("/b/y.txt"))], fileSystems: registry)
        #expect(
            text == "\"\(registry.displayPath(url("/a/x.txt")))\" -> \"\(registry.displayPath(url("/b/y.txt")))\"\n"
        )
    }
}

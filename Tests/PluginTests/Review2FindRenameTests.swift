import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import MultiRenamePlugin

/// Round 2 of the review, Multi-Rename: Search & Replace that cannot hang, a clipboard that is
/// not read for every key, names by path on every file system, `[u]`, the planner's edge cases,
/// the undo store.
@Suite struct Review2FindRename {
    var context: RenameContext = {
        var context = RenameContext()
        context.count = 3
        context.timeZone = TimeZone(identifier: "UTC") ?? .current
        context.locale = Locale(identifier: "en_US_POSIX")
        return context
    }()

    func finishes(within seconds: Double = 60, _ work: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread {
            work()
            done.signal()
        }
        .start()
        return done.wait(timeout: .now() + seconds) == .success
    }

    // MARK: Search & Replace

    @Test func theWildcardMatcherFindsWhatTheRegularExpressionOfItFinds() throws {
        // Many small searches and names, compared with the regular expression that defines the wildcard.
        var generator = SystemRandomNumberGenerator()
        let pieces = ["a", "b", "A", ".", "*", "?", "é", "😀"]
        let nameCharacters = ["a", "b", "A", ".", "é", "😀", "\n", "x"]
        for caseSensitive in [false, true] {
            for _ in 0..<400 {
                let search = (0..<Int.random(in: 1...7, using: &generator))
                    .map { _ in
                        pieces.randomElement(using: &generator)!
                    }
                    .joined()
                let name = (0..<Int.random(in: 0...9, using: &generator))
                    .map { _ in
                        nameCharacters.randomElement(using: &generator)!
                    }
                    .joined()
                let expression = try NSRegularExpression(
                    pattern: SearchReplace.wildcardPattern(search),
                    options: caseSensitive ? [] : [.caseInsensitive]
                )
                let expected = expression.matches(in: name, range: NSRange(location: 0, length: name.utf16.count))
                    .map(
                        \.range
                    )
                let first = expression.firstMatch(in: name, range: NSRange(location: 0, length: name.utf16.count))
                    .map(
                        \.range
                    )
                let matcher = WildcardMatcher(search, caseSensitive: caseSensitive)
                #expect(
                    matcher.matches(in: name, firstOnly: false) == expected,
                    "search \(search.debugDescription) in \(name.debugDescription)"
                )
                #expect(
                    matcher.matches(in: name, firstOnly: true) == (first.map { [$0] } ?? []),
                    "first of \(search.debugDescription) in \(name.debugDescription)"
                )
            }
        }
    }

    @Test func manyStarsInTheSearchAreNotSlowOnALongName() throws {
        var settings = RenameSettings()
        settings.search = String(repeating: "*a", count: 14) + "*b"
        settings.replacement = "X"
        let replace = try SearchReplace(settings)
        let name = String(repeating: "a", count: 250)
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var result: String?
        #expect(finishes { result = replace.replacing(in: name, cancelled: { false }) })
        #expect(result == name)
        // And it still replaces.
        var other = RenameSettings()
        other.search = "a*b"
        other.replacement = "-"
        #expect(try SearchReplace(other).apply(to: "xxaYYbzz") == "xx-zz")
    }

    @Test func aRegexOfTheUserThatBacktracksGivesNoNameInsteadOfHanging() throws {
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var settings = RenameSettings()
        settings.regularExpression = true
        settings.search = "(a*)*b"
        settings.replacement = "x"
        let replace = try SearchReplace(settings)
        let name = String(repeating: "a", count: 32)
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var result: String? = "not run"
        #expect(finishes { result = replace.replacing(in: name, cancelled: { false }) })
        #expect(result == nil && replace.timedOut)
        // In the engine that is the error marker, and the preview says why.
        nonisolated(unsafe) var names: [String?] = []
        nonisolated(unsafe) var problem: (any Error)?
        let subjects = (0..<5)
            .map { _ in
                RenameEntry(FileItem(url: URL(string: "mem:///d/" + name)!, name: name))
            }
        #expect(
            finishes {
                (names, problem) = RenameComputation.names(
                    subjects,
                    settings: settings,
                    context: context,
                    given: nil,
                    fileSystems: FileSystemRegistry()
                )
            }
        )
        #expect(names.allSatisfy { $0 == nil } && problem as? SearchReplace.Problem == .tooSlow("(a*)*b"))
    }

    @Test func aRegexIsEndedWhenThePreviewIsCancelled() throws {
        var settings = RenameSettings()
        settings.regularExpression = true
        settings.search = #"^(\w+[ _-]?)+\.jpg$"#
        let replace = try SearchReplace(settings)
        let flag = CancellationFlag()
        Thread {
            Thread.sleep(forTimeInterval: 0.03)
            flag.cancel()
        }
        .start()
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var result: String? = "not run"
        #expect(
            finishes {
                result = replace.replacing(
                    in: String(repeating: "a", count: 40) + ".png",
                    cancelled: { flag.isCancelled }
                )
            }
        )
        #expect(result == nil && !replace.timedOut)
    }

    // MARK: Names, targets, planner

    @Test func anItemNamedByPathIsRenamedWhereItIsOnEveryFileSystem() {
        let memory = MemoryFileSystem()
        let item = FileItem(url: memory.url("/root/sub/a.txt"), name: "sub/a.txt")
        #expect(RenameEntry(item).name == "a.txt" && RenameEntry.diskName(of: item) == "a.txt")
        var settings = RenameSettings()
        settings.search = "a"
        settings.replacement = "b"
        let preview = RenameComputation.preview(
            [RenameEntry(item)],
            settings: settings,
            context: context,
            fileSystems: FileSystemRegistry()
        )
        #expect(preview.targets.first??.path == "/root/sub/b.txt" && preview.statuses == [.ready])
    }

    @Test func precomposingANameIsARename() {
        let decomposed = "e\u{301}.txt"
        let item = FileItem(
            url: URL(string: "mem:///d/" + decomposed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)!,
            name: decomposed
        )
        var settings = RenameSettings()
        settings.nameMask = "[u][N]"
        let preview = RenameComputation.preview(
            [RenameEntry(item)],
            settings: settings,
            context: context,
            fileSystems: FileSystemRegistry()
        )
        #expect(preview.statuses == [.ready])
        #expect(preview.names.first??.unicodeScalars.map(\.value) == [0xE9, 0x2E, 0x74, 0x78, 0x74])
        let url = URL(string: "mem:///d/a")!
        let planner = RenamePlanner()
        let moved = planner.steps(sources: [url], targets: [URL(string: "mem:///d/e%CC%81")!])
        #expect(moved.count == 1)
    }

    @Test func aNumberedNameIsHeldToTheLongestAName() {
        let long = String(repeating: "é", count: 120) + ".txt"
        let numbered = RenamePlanner.numbered(URL(string: "mem:///d/")!.appending(name: long), 12, isFolder: false)
        #expect(
            numbered.lastPathComponent.utf8.count <= RenamePlanner.longestName
                && numbered.lastPathComponent.hasSuffix(" (12).txt")
        )
        #expect(
            RenamePlanner.numbered(URL(string: "mem:///d/a.txt")!, 2, isFolder: false).lastPathComponent == "a (2).txt"
        )
    }

    @Test func aFolderAndWhatIsInItAreRenamedInsideOut() {
        func url(_ path: String) -> URL { URL(string: "mem://" + path)! }
        let sources = [
            url("/d/dir"), url("/d/dir/a.txt"), url("/d/other.txt"), url("/d/dir/sub"), url("/d/dir/sub/b.txt")
        ]
        let targets = [
            url("/d/dir2"), url("/d/dir/c.txt"), url("/d/o2.txt"), url("/d/dir/sub2"), url("/d/dir/sub/d.txt")
        ]
        let steps = RenamePlanner()
            .steps(
                sources: sources,
                targets: targets,
                isFolder: [true, false, false, true, false]
            )
        let order = steps.map(\.item)
        #expect(Set(order) == [0, 1, 2, 3, 4])
        // Every item comes before the folders that hold it.
        #expect(
            order.firstIndex(of: 4)! < order.firstIndex(of: 3)! && order.firstIndex(of: 3)! < order.firstIndex(of: 0)!
        )
        #expect(order.firstIndex(of: 1)! < order.firstIndex(of: 0)!)
        // Without folders the order is the list's.
        #expect(RenamePlanner().steps(sources: sources, targets: targets).map(\.item) == [0, 1, 2, 3, 4])
    }

    @Test func aRenameOntoANameThatIsNotThereReplacesNothing() throws {
        let box = try Sandbox()
        try box.file("a.txt", "first")
        #expect(!RenameRunner.isSameFile(box.url("a.txt"), box.url("A-missing.txt")))
        let registry = FileSystemRegistry()
        registry.register(LocalFileSystem())
        // The planner was wrong about the volume, and the target is not there: an ordinary rename.
        let step = RenameStep(item: 0, from: box.url("a.txt"), to: box.url("b.txt"), kind: .direct, ontoItself: true)
        let result = RenameRunner(fileSystems: registry).run([step], sources: [box.url("a.txt")])
        #expect(result.failures.isEmpty && box.read("b.txt") == "first" && !box.exists("a.txt"))
    }

    // MARK: Log

    @Test func theLogIsWrittenForTheUserAlone() throws {
        let box = try Sandbox()
        let registry = FileSystemRegistry()
        registry.register(LocalFileSystem())
        let log = box.url("Logs/Test").appendingPathComponent(RenameLog.fileName)
        RenameLog.write([RenamedItem(from: box.url("a"), to: box.url("b"))], to: log, fileSystems: registry)
        let attributes = try FileManager.default.attributesOfItem(atPath: log.path)
        let folder = try FileManager.default.attributesOfItem(atPath: log.deletingLastPathComponent().path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600 && (folder[.posixPermissions] as? Int) == 0o700)
    }
}

@MainActor @Suite struct Review2FindRenameSessions {
    let memory = MemoryFileSystem()
    let settings = MemorySettings()
    let bench: TestBench
    let box: Sandbox

    init() throws {
        box = try Sandbox()
        for name in ["a.txt", "b.txt", "c.txt"] { memory.addFile("/d/" + name, name) }
        memory.addDirectory("/other")
        bench = TestBench(
            plugins: [],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/d"),
            right: memory.url("/other"),
            settings: settings
        )
    }

    func session(
        clipboard: @escaping @Sendable () -> String?,
        changes: (@MainActor () -> Int)?,
        background: Bool = false
    )
        -> MultiRenameSession
    {
        MultiRenameSession(
            kernel: bench.kernel,
            items: bench.left.model.items,
            store: RenameStore(settings: settings),
            settings: .unchanged,
            logDirectory: box.url("log"),
            previewsInBackground: background,
            clipboard: clipboard,
            clipboardChangeCount: changes
        )
    }

    @Test func theClipboardIsReadOnlyWhenAMaskUsesItAndOnlyWhenItChanged() {
        // Used by the session's callbacks, which run one at a time while the test waits for them.
        nonisolated(unsafe) var reads = 0
        // The change count of the clipboard, asked on the main thread.
        @MainActor final class ChangeCount { var value = 1 }
        let count = ChangeCount()
        let session = session(
            clipboard: {
                reads += 1
                return "clip"
            },
            changes: { count.value }
        )
        for mask in ["[N]a", "[N]b", "[N]c", "[N]d"] { session.settings.nameMask = mask }
        #expect(reads == 0)
        session.settings.nameMask = "[X]_[N]"
        #expect(reads == 1 && session.rows.first?.newName == "clip_a.txt")
        for mask in ["[X]1", "[X]2", "[X]3"] { session.settings.nameMask = mask }
        #expect(reads == 1)
        count.value = 2
        session.settings.nameMask = "[X]4"
        #expect(reads == 2)
    }

    @Test func aClipboardThatDoesNotAnswerLeavesThePreviewWithTheErrorMarker() {
        let blocked = DispatchSemaphore(value: 0)
        let session = session(
            clipboard: {
                _ = blocked.wait(timeout: .now() + 5)
                return "late"
            },
            changes: { 1 }
        )
        let start = Date()
        session.settings.nameMask = "[X]"
        // The preview waited a while for the clipboard and then went on without it.
        #expect(session.rows.allSatisfy { $0.newName == nil } && Date().timeIntervalSince(start) < 30)
        blocked.signal()
    }

    @Test func changesOfTheFieldsAreHeldBackForAMomentAndTheLastOneWins() async {
        let session = session(clipboard: { nil }, changes: nil, background: true)
        var changes = 0
        session.onChange = { changes += 1 }
        let base = changes
        for mask in ["[N]1", "[N]2", "[N]3", "[N]4"] { session.settings.nameMask = mask }
        // Nothing was computed for the first three.
        #expect(session.isComputing)
        for _ in 0..<5_000 where session.isComputing { try? await Task.sleep(nanoseconds: 2_000_000) }
        #expect(
            !session.isComputing && session.rows.map(\.newName) == ["a4.txt", "b4.txt", "c4.txt"] && changes - base <= 2
        )
    }

    @Test func twoSortsInARowLeaveTheLastOneInForce() async {
        memory.removeTree("/d")
        for index in 0..<2_500 {
            memory.addFile(
                String(format: "/d/f%04d.txt", index),
                "x",
                modified: Date(timeIntervalSince1970: Double(index))
            )
        }
        bench.left.show(memory.url("/d"), focus: nil, history: .keep, completion: nil)
        let session = session(clipboard: { nil }, changes: nil, background: true)
        session.sort(by: .name, ascending: false)
        session.sort(by: .name, ascending: true)
        for _ in 0..<5_000 where session.isComputing { try? await Task.sleep(nanoseconds: 2_000_000) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(session.rows.first?.entry.name == "f0000.txt" && session.rows.last?.entry.name == "f2499.txt")
    }

    @Test func namesFromAListThatMoveFilesAreAskedAbout() {
        let session = session(clipboard: { nil }, changes: nil)
        session.loadNames(fromText: "x.txt\nsub/y.txt\nz.txt")
        bench.interaction.choiceAnswers = [1]
        var result: RenameRunResult?
        session.start { result = $0 }
        #expect(result?.cancelled == true && memory.exists("/d/a.txt") && !memory.exists("/d/x.txt"))
        bench.interaction.choiceAnswers = [0]
        session.start { result = $0 }
        #expect(result?.renamed.count == 3 && memory.exists("/d/sub/y.txt"))
    }

    @Test func aRunLeavesThePreviewAndTheListAsTheyShouldBe() {
        let session = session(clipboard: { nil }, changes: nil)
        session.settings.nameMask = "n_[N]"
        #expect(session.counts.changing == 3)
        session.start()
        #expect(session.rowCount == 0 && !session.isBusy && memory.exists("/d/n_a.txt"))
    }

    @Test func precomposingRenamesTheFileOnTheLocalDisk() throws {
        let decomposed = "e\u{301}.txt"
        try box.file("p/" + decomposed, "x")
        let local = TestBench(
            plugins: [],
            fileSystems: [LocalFileSystem()],
            left: box.url("p"),
            right: box.url("p"),
            settings: settings
        )
        let item = try #require(local.left.model.items.first)
        var request = RenameSettings()
        request.nameMask = "[u][N]"
        let session = MultiRenameSession(
            kernel: local.kernel,
            items: [item],
            store: RenameStore(settings: settings),
            settings: request,
            logDirectory: box.url("log"),
            previewsInBackground: false
        )
        #expect(session.rows.map(\.status) == [.ready])
        var result: RenameRunResult?
        session.start { result = $0 }
        let names = (try FileManager.default.contentsOfDirectory(atPath: box.url("p").path))
            .map {
                Array($0.unicodeScalars.map(\.value))
            }
        #expect(result?.failures.isEmpty == true && names == [[0xE9, 0x2E, 0x74, 0x78, 0x74]])
        // And Undo writes the accent the way it was.
        local.interaction.choiceAnswers = [0]
        session.undo()
        let back = (try FileManager.default.contentsOfDirectory(atPath: box.url("p").path))
            .map {
                Array($0.unicodeScalars.map(\.value))
            }
        #expect(back == [[0x65, 0x301, 0x2E, 0x74, 0x78, 0x74]])
    }

    @Test func theUndoHistoryNeedsNoDecodingToBeCounted() async {
        let store = RenameStore(settings: settings)
        store.appendUndo([RenamedItem(from: URL(fileURLWithPath: "/d/a"), to: URL(fileURLWithPath: "/d/b"))])
        store.flush()
        // Another store over the same settings, as at the next start of the program.
        let next = RenameStore(settings: MemorySettingsCopy.copy(of: settings))
        #expect(next.undoCount == 1)
        var loaded = false
        next.loadUndo { loaded = true }
        for _ in 0..<5_000 where !loaded { try? await Task.sleep(nanoseconds: 2_000_000) }
        #expect(loaded && next.lastUndo?.count == 1)
    }

    @Test func aRunLargerThanTheLimitIsKeptOnlyForThisSession() {
        let big = (0..<(RenameStore.persistedItemLimit + 5))
            .map {
                RenamedItem(from: URL(fileURLWithPath: "/d/\($0)"), to: URL(fileURLWithPath: "/d/n\($0)"))
            }
        let store = RenameStore(settings: settings)
        store.appendUndo([RenamedItem(from: URL(fileURLWithPath: "/d/a"), to: URL(fileURLWithPath: "/d/b"))])
        store.appendUndo(big)
        store.flush()
        #expect(store.undoCount == 2)
        // Nothing of it, and not the older run either, is saved: Undo would put them back in the wrong order.
        #expect(settings.value([[RenamedItem]].self, forKey: "multirename.undo")?.isEmpty == true)
    }
}

/// A copy of the settings of another store, as a program that is started again would find them.
private enum MemorySettingsCopy {
    static func copy(of settings: MemorySettings) -> MemorySettings {
        let copy = MemorySettings()
        for key in ["multirename.undo", "multirename.undoCount"] { copy.set(settings.data(forKey: key), forKey: key) }
        return copy
    }
}

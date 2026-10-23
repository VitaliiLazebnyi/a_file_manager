import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import MultiRenamePlugin

/// Round 2 of the review, Multi-Rename: Search & Replace that cannot hang, names by path on every
/// file system, `[u]`, the planner's edge cases, the log.
@Suite
internal struct Review2FindRename {
    /// What the masks get: three items, in UTC and the POSIX locale.
    internal var context: RenameContext = {
        var made = RenameContext()
        made.count = 3
        made.timeZone = TimeZone(identifier: "UTC") ?? .current
        made.locale = Locale(identifier: "en_US_POSIX")
        return made
    }()

    /// Whether `work`, run on a thread of its own, ends within the usual wait.
    internal func finishes(_ work: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread {
            work()
            done.signal()
        }
        .start()
        return done.wait(timeout: .now() + Wait.ceiling) == .success
    }

    // MARK: Search & Replace

    /// The wildcard matcher finds in many small names what the regular expression that defines it finds.
    @Test
    internal func theWildcardMatcherFindsWhatTheRegularExpressionOfItFinds() throws {
        // Many small searches and names, compared with the regular expression that defines the wildcard.
        var generator = SystemRandomNumberGenerator()
        let pieces = ["a", "b", "A", ".", "*", "?", "é", "😀"]
        let nameCharacters = ["a", "b", "A", ".", "é", "😀", "\n", "x"]
        for caseSensitive in [false, true] {
            for _ in 0..<400 {
                let search = (0..<Int.random(in: 1...7, using: &generator))
                    .map { _ in
                        pieces[Int.random(in: 0..<pieces.count, using: &generator)]
                    }
                    .joined()
                let name = (0..<Int.random(in: 0...9, using: &generator))
                    .map { _ in
                        nameCharacters[Int.random(in: 0..<nameCharacters.count, using: &generator)]
                    }
                    .joined()
                let expression = try NSRegularExpression(
                    pattern: SearchReplace.wildcardPattern(search),
                    options: caseSensitive ? [] : [.caseInsensitive]
                )
                let whole = NSRange(location: 0, length: name.utf16.count)
                let expected = expression.matches(in: name, range: whole).map(\.range)
                let first = expression.firstMatch(in: name, range: whole).map(\.range)
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

    /// Many stars in the search are no slower on a long name than the name times the search, and still replace.
    @Test
    internal func manyStarsInTheSearchAreNotSlowOnALongName() throws {
        var settings = RenameSettings()
        settings.search = String(repeating: "*a", count: 14) + "*b"
        settings.replacement = "X"
        let replace = try SearchReplace(settings)
        let name = String(repeating: "a", count: 250)
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var result: String?
        #expect(finishes { result = replace.replacing(in: name) { false } })
        #expect(result == name)
        // And it still replaces.
        var other = RenameSettings()
        other.search = "a*b"
        other.replacement = "-"
        #expect(try SearchReplace(other).apply(to: "xxaYYbzz") == "xx-zz")
    }

    /// A regular expression of the user that backtracks gives no name and says why, instead of hanging.
    @Test
    internal func aRegexOfTheUserThatBacktracksGivesNoNameInsteadOfHanging() throws {
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var settings = RenameSettings()
        settings.regularExpression = true
        settings.search = "(a*)*b"
        settings.replacement = "x"
        let replace = try SearchReplace(settings)
        let name = String(repeating: "a", count: 32)
        // Used by the work on its own thread only while the test waits for it to finish.
        nonisolated(unsafe) var result: String? = "not run"
        #expect(finishes { result = replace.replacing(in: name) { false } })
        #expect(result == nil && replace.timedOut)
        // In the engine that is the error marker, and the preview says why.
        nonisolated(unsafe) var names: [String?] = []
        nonisolated(unsafe) var problem: (any Error)?
        let url = try #require(URL(string: "mem:///d/" + name))
        let subjects = (0..<5).map { _ in RenameEntry(FileItem(url: url, name: name)) }
        #expect(
            finishes {
                (names, problem) = RenameComputation.names(
                    RenameRequest(entries: subjects, settings: settings, context: context),
                    fileSystems: FileSystemRegistry(),
                    subjects: []
                ) { false }
            }
        )
        #expect(names.allSatisfy { $0 == nil } && problem as? SearchReplace.Problem == .tooSlow("(a*)*b"))
    }

    /// A regular expression at work on a name ends when the preview is cancelled, without counting a timeout.
    @Test
    internal func aRegexIsEndedWhenThePreviewIsCancelled() throws {
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
                result = replace.replacing(in: String(repeating: "a", count: 40) + ".png") { flag.isCancelled }
            }
        )
        #expect(result == nil && !replace.timedOut)
    }

    // MARK: Names, targets, planner

    /// An item that the list names by its path is renamed in its own folder, on every file system.
    @Test
    internal func anItemNamedByPathIsRenamedWhereItIsOnEveryFileSystem() {
        let memory = MemoryFileSystem()
        let item = FileItem(url: memory.url("/root/sub/a.txt"), name: "sub/a.txt")
        #expect(RenameEntry(item).name == "a.txt" && RenameEntry.diskName(of: item) == "a.txt")
        var settings = RenameSettings()
        settings.search = "a"
        settings.replacement = "b"
        let preview = RenameComputation.preview(
            RenameRequest(entries: [RenameEntry(item)], settings: settings, context: context),
            fileSystems: FileSystemRegistry(),
            cache: RenameCache(),
            cancellation: nil
        ) { false }
        #expect(preview.targets.first??.path == "/root/sub/b.txt" && preview.statuses == [.ready])
    }

    /// Precomposing a decomposed name is a rename, which the planner carries out.
    @Test
    internal func precomposingANameIsARename() throws {
        let decomposed = "e\u{301}.txt"
        let encoded = try #require(decomposed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed))
        let item = FileItem(url: try #require(URL(string: "mem:///d/" + encoded)), name: decomposed)
        var settings = RenameSettings()
        settings.nameMask = "[u][N]"
        let preview = RenameComputation.preview(
            RenameRequest(entries: [RenameEntry(item)], settings: settings, context: context),
            fileSystems: FileSystemRegistry(),
            cache: RenameCache(),
            cancellation: nil
        ) { false }
        #expect(preview.statuses == [.ready])
        #expect(preview.names.first??.unicodeScalars.map(\.value) == [0xE9, 0x2E, 0x74, 0x78, 0x74])
        let url = try #require(URL(string: "mem:///d/a"))
        let accented = try #require(URL(string: "mem:///d/e%CC%81"))
        let planner = RenamePlanner()
        let moved = planner.steps(
            sources: [url],
            targets: [accented],
            isFolder: [],
            temporaryName: nil
        ) { false }
        #expect(moved.count == 1)
    }

    /// A numbered name is held to the longest a name can be.
    @Test
    internal func aNumberedNameIsHeldToTheLongestAName() throws {
        let long = String(repeating: "é", count: 120) + ".txt"
        let folder = try #require(URL(string: "mem:///d/"))
        let numbered = RenamePlanner.numbered(folder.appending(name: long), 12, isFolder: false)
        #expect(
            numbered.lastPathComponent.utf8.count <= RenamePlanner.longestName
                && numbered.lastPathComponent.hasSuffix(" (12).txt")
        )
        let short = try #require(URL(string: "mem:///d/a.txt"))
        #expect(RenamePlanner.numbered(short, 2, isFolder: false).lastPathComponent == "a (2).txt")
    }

    /// A folder and what is in it are renamed inside out; without folders the order is the list's.
    @Test
    internal func aFolderAndWhatIsInItAreRenamedInsideOut() throws {
        func url(_ path: String) throws -> URL { try #require(URL(string: "mem://" + path)) }
        let sources = try [
            url("/d/dir"), url("/d/dir/a.txt"), url("/d/other.txt"), url("/d/dir/sub"), url("/d/dir/sub/b.txt")
        ]
        let targets: [URL?] = try [
            url("/d/dir2"), url("/d/dir/c.txt"), url("/d/o2.txt"), url("/d/dir/sub2"), url("/d/dir/sub/d.txt")
        ]
        let steps = RenamePlanner()
            .steps(
                sources: sources,
                targets: targets,
                isFolder: [true, false, false, true, false],
                temporaryName: nil
            ) { false }
        let order = steps.map(\.item)
        #expect(Set(order) == [0, 1, 2, 3, 4])
        // Every item comes before the folders that hold it.
        func place(_ item: Int) -> Int { order.firstIndex(of: item) ?? order.count }
        #expect(place(4) < place(3) && place(3) < place(0))
        #expect(place(1) < place(0))
        // Without folders the order is the list's.
        let plain = RenamePlanner()
            .steps(sources: sources, targets: targets, isFolder: [], temporaryName: nil) { false }
        #expect(plain.map(\.item) == [0, 1, 2, 3, 4])
    }

    /// A rename onto a name that is not there replaces nothing, whatever the planner thought of the volume.
    @Test
    internal func aRenameOntoANameThatIsNotThereReplacesNothing() throws {
        let box = try Sandbox()
        try box.file("a.txt", "first")
        #expect(!RenameRunner.isSameFile(box.url("a.txt"), box.url("A-missing.txt")))
        let registry = FileSystemRegistry()
        registry.register(LocalFileSystem())
        // The planner was wrong about the volume, and the target is not there: an ordinary rename.
        let step = RenameStep(
            item: 0,
            from: box.url("a.txt"),
            destination: box.url("b.txt"),
            kind: .direct,
            ontoItself: true
        )
        let result = RenameRunner(fileSystems: registry, cancellation: CancellationFlag())
            .run([step], sources: [box.url("a.txt")])
        #expect(result.failures.isEmpty && box.read("b.txt") == "first" && !box.exists("a.txt"))
    }

    // MARK: Log

    /// The log is written in a folder and a file that only the user can read.
    @Test
    internal func theLogIsWrittenForTheUserAlone() throws {
        let box = try Sandbox()
        let registry = FileSystemRegistry()
        registry.register(LocalFileSystem())
        let log = box.url("Logs/Test").appendingPathComponent(RenameLog.fileName)
        RenameLog.write([RenamedItem(from: box.url("a"), destination: box.url("b"))], to: log, fileSystems: registry)
        let attributes = try FileManager.default.attributesOfItem(atPath: log.path)
        let folder = try FileManager.default.attributesOfItem(atPath: log.deletingLastPathComponent().path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600 && (folder[.posixPermissions] as? Int) == 0o700)
    }
}

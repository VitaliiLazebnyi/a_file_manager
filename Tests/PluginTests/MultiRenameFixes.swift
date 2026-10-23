import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import MultiRenamePlugin

/// Fixes found in review: names by path, case folding per folder, numbers that used to trap,
/// the planner's cost, Undo and the store.
@MainActor
@Suite
internal struct MultiRenameFixes {
    /// Three items, in UTC and the POSIX locale.
    internal var context: RenameContext = {
        var made = RenameContext()
        made.count = 3
        made.timeZone = TimeZone(identifier: "UTC") ?? .current
        made.locale = Locale(identifier: "en_US_POSIX")
        return made
    }()

    /// The name the mask gives `a.txt`, the first of the list.
    internal func name(_ mask: String) -> String? {
        name(mask, subject: "a.txt")
    }

    /// The name the mask gives `subject`, the first of the list.
    internal func name(_ mask: String, subject: String) -> String? {
        name(mask, ext: "[E]", subject: subject, counter: CounterDefinition(), index: 0)
    }

    /// The name the masks give `subject` at `index` of the list, with `counter` for `[C]`.
    internal func name(
        _ mask: String,
        ext: String,
        subject: String,
        counter: CounterDefinition,
        index: Int
    ) -> String? {
        var settings = RenameSettings()
        settings.nameMask = mask
        settings.extensionMask = ext
        settings.counter = counter
        return RenameEngine(settings, context: context).newName(for: RenameSubject(name: subject), index: index)
    }

    // MARK: Masks

    /// A dot at the end belongs to the name, and a dot at the start starts no extension.
    @Test
    internal func aTrailingDotBelongsToTheName() {
        #expect(name("[N]", subject: "Acme Inc.") == "Acme Inc.")
        #expect(name("[N]-x", subject: "Acme Inc.") == "Acme Inc.-x")
        #expect(name("[E]", subject: "Acme Inc.")?.isEmpty == true)
        #expect(name("[N]", subject: "a.b.txt") == "a.b.txt")
        #expect(name("[N]", subject: ".zshrc") == ".zshrc")
    }

    /// Counters beyond what a number holds give the error marker, not a crash.
    @Test
    internal func hugeCountersGiveTheErrorMarker() {
        let big = CounterDefinition(start: Int.max - 1, step: 1, digits: 1)
        #expect(counted("[C]", big, index: 0) == "9223372036854775806.txt")
        #expect(counted("[C]", big, index: 5) == nil)
        #expect(counted("[C]", CounterDefinition(start: 1, step: Int.max, digits: 1), index: 2) == nil)
        #expect(counted("[C]", CounterDefinition(start: Int.min, step: -1, digits: 1), index: 1) == nil)
        #expect(name("[Czzzzzzzzzzzzzzzzzzzz]") == nil)
        #expect(name("[Czzzzzzzzzzzzzz+1]") == nil)
        #expect(counted("[Caa+1]", CounterDefinition(), index: 1) == "ab.txt")
        #expect(counted("[c3]", CounterDefinition(start: Int.max, step: 5, digits: 1), index: 0) == nil)
    }

    /// The name the mask gives `a.txt` at `index` of the list, with `counter` for `[C]`.
    internal func counted(_ mask: String, _ counter: CounterDefinition, index: Int) -> String? {
        name(mask, ext: "[E]", subject: "a.txt", counter: counter, index: index)
    }

    /// Widths beyond the longest name are held to it.
    @Test
    internal func hugeWidthsAreCapped() {
        let wide = name("[C:999999999]")
        #expect(wide?.count == 255 + 4)
        #expect(name("[N01,999999999]", subject: "abc.txt")?.count == 255 + 4)
        #expect(counted("[C]", CounterDefinition(start: 1, step: 1, digits: 10), index: 0) == "0000000001.txt")
    }

    // MARK: Planner

    /// The local location of `name` in `/d`.
    internal func url(_ name: String) -> URL { url(name, in: "/d") }

    /// The local location of `name` in `folder`.
    internal func url(_ name: String, in folder: String) -> URL { URL(fileURLWithPath: folder + "/" + name) }

    /// Auto-rename counts on from where it was instead of starting over for each item.
    @Test
    internal func autoRenameCountsOnInsteadOfStartingOver() {
        let planner = RenamePlanner()
        let sources = (0..<2_000).map { url("s\($0).txt") }
        let targets = sources.map { _ in Optional(url("same.txt")) }
        // Counting from 2 again for each of them takes seconds of processor time (the time
        // on the clock would count what the rest of a busy machine does).
        let start = ThreadTime.used
        let result = planner.autoRenamed(
            sources: sources,
            targets: targets,
            isFolder: sources.map { _ in false },
            existing: Set(sources.map(planner.key))
        )
        #expect(ThreadTime.used - start < 2)
        let names = result.compactMap { $0?.lastPathComponent }
        #expect(
            Set(names).count == 2_000 && names.first == "same.txt" && names[1] == "same (2).txt"
                && names.last == "same (2000).txt"
        )
        // A taken number is still skipped.
        let taken = planner.autoRenamed(
            sources: [url("a"), url("b")],
            targets: [url("x.txt"), url("x.txt")],
            isFolder: [false, false],
            existing: Set([url("a"), url("b"), url("x.txt"), url("x (2).txt")].map(planner.key))
        )
        #expect(taken.map { $0?.lastPathComponent } == ["x (3).txt", "x (4).txt"])
    }

    /// Skipping follows a chain of items that wait for each other once.
    @Test
    internal func skippingFollowsTheChainOnce() {
        let planner = RenamePlanner()
        // 1 -> 2 -> 3 -> ... -> n, and n wants a file that is not in the list.
        let count = 3_000
        let sources = (1...count).map { url("\($0)") }
        var targets: [URL?] = (2...count).map { url("\($0)") }
        targets.append(url("outside"))
        let existing = Set((sources + [url("outside")]).map(planner.key))
        let start = ThreadTime.used
        let skipped = planner.skippingConflicts(sources: sources, targets: targets, existing: existing)
        #expect(ThreadTime.used - start < 2)
        #expect(skipped.allSatisfy { $0 == nil })
        // Items that do not depend on the conflict still move.
        let mixed = planner.skippingConflicts(
            sources: [url("a"), url("b"), url("c")],
            targets: [url("b"), url("outside"), url("z")],
            existing: Set(["a", "b", "c", "outside"].map { planner.key(url($0)) })
        )
        #expect(mixed.map { $0?.lastPathComponent } == [nil, nil, "z"])
    }

    /// Letter case is folded per folder.
    @Test
    internal func caseIsFoldedPerFolder() {
        let planner = RenamePlanner(foldedFolders: [url("x", in: "/mac").deletingLastPathComponent().locationKey])
        #expect(planner.key(url("Name.TXT", in: "/mac")) == planner.key(url("name.txt", in: "/mac")))
        #expect(planner.key(url("Name.TXT", in: "/linux")) != planner.key(url("name.txt", in: "/linux")))
        let steps = planner.steps(
            sources: [url("A", in: "/mac"), url("B", in: "/linux")],
            targets: [url("a", in: "/mac"), url("b", in: "/linux")],
            isFolder: [],
            temporaryName: nil
        ) { false }
        #expect(steps.map(\.ontoItself) == [true, false])
    }

    /// A move onto the file itself never overwrites another file.
    @Test
    internal func aReplacingMoveNeverOverwritesAnotherFile() throws {
        let box = try Sandbox()
        try box.file("a.txt", "first")
        try box.file("b.txt", "second")
        let registry = FileSystemRegistry()
        registry.register(LocalFileSystem())
        // A planner that wrongly took the volume for case-insensitive: a.txt "onto itself" b.txt.
        let step = RenameStep(
            item: 0,
            from: box.url("a.txt"),
            destination: box.url("b.txt"),
            kind: .direct,
            ontoItself: true
        )
        let result = RenameRunner(fileSystems: registry, cancellation: CancellationFlag())
            .run([step], sources: [box.url("a.txt")])
        #expect(result.renamed.isEmpty && result.failures.count == 1)
        #expect(box.read("a.txt") == "first" && box.read("b.txt") == "second")
        #expect(
            RenameRunner.isSameFile(box.url("a.txt"), box.url("a.txt"))
                && !RenameRunner.isSameFile(box.url("a.txt"), box.url("b.txt"))
        )
        // A target that is not there is no file at all: the volume tells the cases apart after all,
        // and the rename is an ordinary one that replaces nothing.
        #expect(!RenameRunner.isSameFile(box.url("a.txt"), box.url("missing")))
    }

    // MARK: Lists named by path

    /// Items named by their path are renamed where they are.
    @MainActor
    @Test
    internal func itemsNamedByPathAreRenamedWhereTheyAre() throws {
        let box = try Sandbox()
        try box.file("sub/a.txt", "a")
        try box.file("sub/deep/b.txt", "b")
        let memory = MemoryFileSystem()
        let bench = TestBench(
            plugins: [],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/"),
            right: memory.url("/"),
            settings: MemorySettings()
        )
        let items = [
            FileItem(url: box.url("sub/a.txt"), name: "sub/a.txt"),
            FileItem(url: box.url("sub/deep/b.txt"), name: "sub/deep/b.txt")
        ]
        var settings = RenameSettings()
        settings.nameMask = "[N]_x"
        let session = MultiRenameSession(
            kernel: bench.kernel,
            items: items,
            store: RenameStore(settings: MemorySettings()),
            settings: settings,
            logDirectory: box.url("log"),
            previewsInBackground: false,
            clipboard: { nil },
            clipboardChangeCount: nil
        )
        #expect(
            session.rows.map(\.status) == [.ready, .ready] && session.rows.map(\.newName) == ["a_x.txt", "b_x.txt"]
        )
        session.start(completion: nil)
        #expect(box.exists("sub/a_x.txt") && box.exists("sub/deep/b_x.txt"))
        #expect(!box.exists("sub/sub") && !box.exists("sub/a.txt"))
        // A list that is not changed by the masks stays unchanged.
        let again = MultiRenameSession(
            kernel: bench.kernel,
            items: [FileItem(url: box.url("sub/a_x.txt"), name: "sub/a_x.txt")],
            store: RenameStore(settings: MemorySettings()),
            settings: .unchanged,
            logDirectory: box.url("log"),
            previewsInBackground: false,
            clipboard: { nil },
            clipboardChangeCount: nil
        )
        #expect(again.rows.map(\.status) == [.unchanged])
    }
}

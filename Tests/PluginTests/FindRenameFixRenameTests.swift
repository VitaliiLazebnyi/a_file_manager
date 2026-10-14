import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import MultiRenamePlugin

/// Fixes found in review: names by path, case folding per folder, numbers that used to trap,
/// the planner's cost, Undo and the store.
@MainActor @Suite struct MultiRenameFixes {
    var context: RenameContext = {
        var context = RenameContext()
        context.count = 3
        context.timeZone = TimeZone(identifier: "UTC") ?? .current
        context.locale = Locale(identifier: "en_US_POSIX")
        return context
    }()

    func name(
        _ mask: String, ext: String = "[E]", subject: String = "a.txt", counter: CounterDefinition? = nil,
        index: Int = 0
    ) -> String? {
        var settings = RenameSettings()
        settings.nameMask = mask
        settings.extensionMask = ext
        if let counter { settings.counter = counter }
        return RenameEngine(settings, context: context).newName(for: RenameSubject(name: subject), index: index)
    }

    // MARK: Masks

    @Test func aTrailingDotBelongsToTheName() {
        #expect(name("[N]", subject: "Acme Inc.") == "Acme Inc.")
        #expect(name("[N]-x", subject: "Acme Inc.") == "Acme Inc.-x")
        #expect(name("[E]", ext: "[E]", subject: "Acme Inc.") == "")
        #expect(name("[N]", subject: "a.b.txt") == "a.b.txt")
        #expect(name("[N]", subject: ".zshrc") == ".zshrc")
    }

    @Test func hugeCountersGiveTheErrorMarker() {
        let big = CounterDefinition(start: Int.max - 1, step: 1, digits: 1)
        #expect(name("[C]", counter: big, index: 0) == "9223372036854775806.txt")
        #expect(name("[C]", counter: big, index: 5) == nil)
        #expect(name("[C]", counter: CounterDefinition(start: 1, step: Int.max, digits: 1), index: 2) == nil)
        #expect(name("[C]", counter: CounterDefinition(start: Int.min, step: -1, digits: 1), index: 1) == nil)
        #expect(name("[Czzzzzzzzzzzzzzzzzzzz]") == nil)
        #expect(name("[Czzzzzzzzzzzzzz+1]") == nil)
        #expect(name("[Caa+1]", index: 1) == "ab.txt")
        #expect(name("[c3]", counter: CounterDefinition(start: Int.max, step: 5, digits: 1)) == nil)
    }

    @Test func hugeWidthsAreCapped() {
        let counted = name("[C:999999999]")
        #expect(counted?.count == 255 + 4)
        #expect(name("[N01,999999999]", subject: "abc.txt")?.count == 255 + 4)
        #expect(name("[C]", counter: CounterDefinition(start: 1, step: 1, digits: 10)) == "0000000001.txt")
    }

    // MARK: Planner

    func url(_ name: String, in folder: String = "/d") -> URL { URL(fileURLWithPath: folder + "/" + name) }

    @Test func autoRenameCountsOnInsteadOfStartingOver() {
        let planner = RenamePlanner()
        let sources = (0..<2_000).map { url("s\($0).txt") }
        let targets = sources.map { _ in Optional(url("same.txt")) }
        let start = Date()
        let result = planner.autoRenamed(
            sources: sources, targets: targets, isFolder: sources.map { _ in false },
            existing: Set(sources.map(planner.key)))
        #expect(Date().timeIntervalSince(start) < 2)
        let names = result.compactMap { $0?.lastPathComponent }
        #expect(
            Set(names).count == 2_000 && names.first == "same.txt" && names[1] == "same (2).txt"
                && names.last == "same (2000).txt")
        // A taken number is still skipped.
        let taken = planner.autoRenamed(
            sources: [url("a"), url("b")], targets: [url("x.txt"), url("x.txt")], isFolder: [false, false],
            existing: Set([url("a"), url("b"), url("x.txt"), url("x (2).txt")].map(planner.key)))
        #expect(taken.map { $0?.lastPathComponent } == ["x (3).txt", "x (4).txt"])
    }

    @Test func skippingFollowsTheChainOnce() {
        let planner = RenamePlanner()
        // 1 -> 2 -> 3 -> ... -> n, and n wants a file that is not in the list.
        let n = 3_000
        let sources = (1...n).map { url("\($0)") }
        var targets: [URL?] = (2...n).map { url("\($0)") }
        targets.append(url("outside"))
        let existing = Set((sources + [url("outside")]).map(planner.key))
        let start = Date()
        let skipped = planner.skippingConflicts(sources: sources, targets: targets, existing: existing)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(skipped.allSatisfy { $0 == nil })
        // Items that do not depend on the conflict still move.
        let mixed = planner.skippingConflicts(
            sources: [url("a"), url("b"), url("c")], targets: [url("b"), url("outside"), url("z")],
            existing: Set(["a", "b", "c", "outside"].map { planner.key(url($0)) }))
        #expect(mixed.map { $0?.lastPathComponent } == [nil, nil, "z"])
    }

    @Test func caseIsFoldedPerFolder() {
        let planner = RenamePlanner(foldedFolders: [url("x", in: "/mac").deletingLastPathComponent().locationKey])
        #expect(planner.key(url("Name.TXT", in: "/mac")) == planner.key(url("name.txt", in: "/mac")))
        #expect(planner.key(url("Name.TXT", in: "/linux")) != planner.key(url("name.txt", in: "/linux")))
        let steps = planner.steps(
            sources: [url("A", in: "/mac"), url("B", in: "/linux")],
            targets: [url("a", in: "/mac"), url("b", in: "/linux")])
        #expect(steps.map(\.ontoItself) == [true, false])
    }

    @Test func aReplacingMoveNeverOverwritesAnotherFile() throws {
        let box = try Sandbox()
        try box.file("a.txt", "first")
        try box.file("b.txt", "second")
        let registry = FileSystemRegistry()
        registry.register(LocalFileSystem())
        // A planner that wrongly took the volume for case-insensitive: a.txt "onto itself" b.txt.
        let step = RenameStep(item: 0, from: box.url("a.txt"), to: box.url("b.txt"), kind: .direct, ontoItself: true)
        let result = RenameRunner(fileSystems: registry).run([step], sources: [box.url("a.txt")])
        #expect(result.renamed.isEmpty && result.failures.count == 1)
        #expect(box.read("a.txt") == "first" && box.read("b.txt") == "second")
        #expect(
            RenameRunner.isSameFile(box.url("a.txt"), box.url("a.txt"))
                && !RenameRunner.isSameFile(box.url("a.txt"), box.url("b.txt")))
        // A target that is not there is no file at all: the volume tells the cases apart after all,
        // and the rename is an ordinary one that replaces nothing.
        #expect(!RenameRunner.isSameFile(box.url("a.txt"), box.url("missing")))
    }

    // MARK: Lists named by path

    @MainActor @Test func itemsNamedByPathAreRenamedWhereTheyAre() throws {
        let box = try Sandbox()
        try box.file("sub/a.txt", "a")
        try box.file("sub/deep/b.txt", "b")
        let memory = MemoryFileSystem()
        let bench = TestBench(
            plugins: [], fileSystems: [LocalFileSystem(), memory], left: memory.url("/"), right: memory.url("/"),
            settings: MemorySettings())
        let items = [
            FileItem(url: box.url("sub/a.txt"), name: "sub/a.txt", isDirectory: false),
            FileItem(url: box.url("sub/deep/b.txt"), name: "sub/deep/b.txt", isDirectory: false)
        ]
        var settings = RenameSettings()
        settings.nameMask = "[N]_x"
        let session = MultiRenameSession(
            kernel: bench.kernel, items: items, store: RenameStore(settings: MemorySettings()), settings: settings,
            logDirectory: box.url("log"), previewsInBackground: false)
        #expect(
            session.rows.map(\.status) == [.ready, .ready] && session.rows.map(\.newName) == ["a_x.txt", "b_x.txt"])
        session.start()
        #expect(box.exists("sub/a_x.txt") && box.exists("sub/deep/b_x.txt"))
        #expect(!box.exists("sub/sub") && !box.exists("sub/a.txt"))
        // A list that is not changed by the masks stays unchanged.
        let again = MultiRenameSession(
            kernel: bench.kernel,
            items: [FileItem(url: box.url("sub/a_x.txt"), name: "sub/a_x.txt", isDirectory: false)],
            store: RenameStore(settings: MemorySettings()), settings: .unchanged, logDirectory: box.url("log"),
            previewsInBackground: false)
        #expect(again.rows.map(\.status) == [.unchanged])
    }

    // MARK: Cache

    @Test func aCachedPreviewGivesTheSameAnswer() throws {
        let box = try Sandbox()
        for name in ["a.txt", "b.txt", "c.txt"] { try box.file(name) }
        let registry = FileSystemRegistry()
        registry.register(LocalFileSystem())
        let entries = ["a.txt", "b.txt", "c.txt"].map {
            RenameEntry(FileItem(url: box.url($0), name: $0, isDirectory: false))
        }
        var settings = RenameSettings()
        settings.nameMask = "b"
        let cache = RenameCache()
        let first = RenameComputation.preview(
            entries, settings: settings, context: context, fileSystems: registry, cache: cache)
        // The folder changes behind the cache's back: only a fresh look sees it.
        try box.file("d.txt")
        settings.nameMask = "d"
        let second = RenameComputation.preview(
            entries, settings: settings, context: context, fileSystems: registry, cache: cache)
        let fresh = RenameComputation.preview(entries, settings: settings, context: context, fileSystems: registry)
        #expect(first.statuses == [.duplicate, .unchanged, .duplicate] || first.statuses.contains(.duplicate))
        #expect(second.statuses.allSatisfy { $0 == .duplicate })
        #expect(fresh.statuses.allSatisfy { $0 == .duplicate })
        let cancelled = RenameComputation.preview(
            entries, settings: settings, context: context, fileSystems: registry, cache: cache, isCancelled: { true })
        #expect(cancelled.names.count == 3)
    }

    // MARK: Store

    @MainActor @Test func undoHistoryLivesInMemoryAndIsSaved() {
        let settings = MemorySettings()
        let store = RenameStore(settings: settings)
        let run = (0..<5_000).map {
            RenamedItem(from: URL(fileURLWithPath: "/d/\($0)"), to: URL(fileURLWithPath: "/d/n\($0)"))
        }
        store.appendUndo(run)
        store.appendUndo([run[0]])
        #expect(store.undoCount == 2 && store.lastUndo?.count == 1)
        // Another store on the same settings sees it at once, and so does a fresh decode of the saved copy.
        #expect(RenameStore(settings: settings).undoCount == 2)
        store.flush()
        #expect(settings.value([[RenamedItem]].self, forKey: "multirename.undo")?.map(\.count) == [5_000, 1])
        store.replaceLastUndo(with: [])
        #expect(store.undoCount == 1)
        let start = Date()
        for _ in 0..<10_000 { _ = store.undoCount }
        #expect(Date().timeIntervalSince(start) < 1)
        let before = store.revision
        store.remember("[N]", in: .nameMask)
        #expect(store.revision == before + 1 && store.history(.nameMask) == ["[N]"])
    }

    @Test func persistedUndoIsCapped() async {
        let settings = MemorySettings()
        let store = await MainActor.run { RenameStore(settings: settings) }
        let big = (0..<(RenameStore.persistedItemLimit - 10)).map {
            RenamedItem(from: URL(fileURLWithPath: "/d/\($0)"), to: URL(fileURLWithPath: "/d/n\($0)"))
        }
        await MainActor.run {
            store.appendUndo(big)
            store.appendUndo(Array(big.prefix(100)))
            store.flush()
            #expect(store.undoCount == 2)
            #expect(settings.value([[RenamedItem]].self, forKey: "multirename.undo")?.map(\.count) == [100])
        }
    }
}

/// Undo that cannot finish, and sorting, through a session on a file system in memory.
@MainActor @Suite struct MultiRenameFixSessions {
    let memory = MemoryFileSystem()
    let settings = MemorySettings()
    let plugin: MultiRenamePlugin
    let bench: TestBench
    let box: Sandbox

    init() throws {
        box = try Sandbox()
        for name in ["b.txt", "a.jpg", "c.txt", "a.txt"] { memory.addFile("/d/" + name, name) }
        memory.addDirectory("/other")
        plugin = MultiRenamePlugin(opensWindows: false, logDirectory: box.url("log"))
        bench = TestBench(
            plugins: [plugin], fileSystems: [LocalFileSystem(), memory], left: memory.url("/d"),
            right: memory.url("/other"), settings: settings)
    }

    func open(_ pattern: String) -> MultiRenameSession {
        bench.left.model.clearSelection()
        bench.left.model.select(mask: pattern)
        #expect(bench.commands.perform(.multiRename))
        return plugin.session!
    }

    @Test func sortingByExtensionKeepsEqualItemsInOrder() {
        let session = open("*")
        session.sort(by: .ext, ascending: true)
        #expect(session.rows.map(\.entry.name) == ["a.jpg", "a.txt", "b.txt", "c.txt"])
        session.sort(by: .ext, ascending: false)
        #expect(session.rows.map(\.entry.name) == ["c.txt", "b.txt", "a.txt", "a.jpg"])
        session.sort(by: .name, ascending: true)
        #expect(session.rows.map(\.entry.name) == ["a.jpg", "a.txt", "b.txt", "c.txt"])
    }

    @Test func aRunThatCanNeverBeUndoneDoesNotBlockEarlierOnes() {
        var session = open("a.*")
        session.settings.nameMask = "first[C]"
        session.start()
        session = open("c.txt")
        session.settings.nameMask = "second"
        session.start()
        #expect(RenameStore(settings: settings).undoCount == 2)
        // The file of the newer run is deleted by somebody else: that run cannot be taken back.
        try? memory.remove(memory.url("/d/second.txt"))
        bench.ui.choiceAnswers = [0, 0]
        session = open("*")
        var left: [RenamedItem]?
        session.undo { left = $0 }
        #expect(left?.count == 1 && session.canUndo)
        #expect(RenameStore(settings: settings).undoCount == 1)
        session.undo()
        #expect(!session.canUndo && memory.exists("/d/a.jpg") && memory.exists("/d/a.txt"))
    }
}

import AFMContracts
import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import CompareContentPlugin
@testable import DirectorySyncPlugin
@testable import FileToolsPlugin
@testable import FindFilesPlugin
@testable import MultiRenamePlugin
@testable import SelectionPlugin

// MARK: Helpers

/// A file system that forwards everything to a `MemoryFileSystem` and says when a listing, a
/// read or a write has been opened, so that a test cancels while the operation is under way
/// and not before it.
private final class ProbingFileSystem: FileSystemProvider {
    let memory: MemoryFileSystem
    let listing = DispatchSemaphore(value: 0)
    let reading = DispatchSemaphore(value: 0)
    let writing = DispatchSemaphore(value: 0)

    init(_ memory: MemoryFileSystem) { self.memory = memory }

    var scheme: String { memory.scheme }
    var capabilities: FileSystemCapabilities { memory.capabilities }
    func capabilities(for url: URL) -> FileSystemCapabilities { memory.capabilities(for: url) }
    func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try memory.list(directory, showHidden: showHidden)
    }
    func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
        listing.signal()
        return try memory.list(directory, showHidden: showHidden, cancellation: cancellation)
    }
    func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag, receive: ([FileItem]) -> Bool) throws
    {
        listing.signal()
        try memory.list(directory, showHidden: showHidden, cancellation: cancellation, receive: receive)
    }
    func item(at url: URL) -> FileItem? { memory.item(at: url) }
    func item(at url: URL, cancellation: CancellationFlag) -> FileItem? {
        memory.item(at: url, cancellation: cancellation)
    }
    func parent(of directory: URL) -> URL? { memory.parent(of: directory) }
    func read(_ url: URL) throws -> any FileReader { try memory.read(url) }
    func read(_ url: URL, cancellation: CancellationFlag) throws -> any FileReader {
        let reader = try memory.read(url, cancellation: cancellation)
        reading.signal()
        return reader
    }
    func createDirectory(at url: URL) throws { try memory.createDirectory(at: url) }
    func write(_ url: URL) throws -> any FileWriter { try memory.write(url) }
    func write(_ url: URL, cancellation: CancellationFlag) throws -> any FileWriter {
        let writer = try memory.write(url, cancellation: cancellation)
        writing.signal()
        return writer
    }
    func remove(_ url: URL) throws { try memory.remove(url) }
    func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try memory.move(source, to: destination, replacing: replacing)
    }
    func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try memory.copy(source, to: destination, progress: progress)
    }
}

/// What a background thread produced.
private final class Outcome<Value> {
    private let lock = NSLock()
    private var stored: Value?
    var value: Value? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

/// Runs `work` on its own thread; the semaphore is signalled when it ends.
private func background(_ work: @escaping () -> Void) -> DispatchSemaphore {
    let done = DispatchSemaphore(value: 0)
    Thread {
        work()
        done.signal()
    }.start()
    return done
}

/// Sets the flag from a thread of its own, as a Cancel button would.
private func cancelFromThread(_ flag: CancellationFlag) {
    _ = background { flag.cancel() }.wait(timeout: .now() + 30)
}

private let adoptWait = 30.0

/// Two names that read the same and are two files on a server or a disk from elsewhere.
private let composed = "caf\u{e9}.txt"
private let decomposed = "cafe\u{301}.txt"

private func isExactly(_ name: String, _ other: String) -> Bool { name.utf8.elementsEqual(other.utf8) }

// MARK: Selection

@MainActor @Suite struct ToolsAdoptSelection {
    let memory = MemoryFileSystem()

    init() {
        memory.addFile("/A/" + composed, "12345")
        memory.addFile("/A/" + decomposed, "1")
        memory.addFile("/A/plain.md", "x")
        memory.addDirectory("/B")
    }

    let pasteboard = NSPasteboard.withUniqueName()

    func makeBench() -> TestBench {
        TestBench(
            plugins: [SelectionPlugin(pasteboard: pasteboard, background: false)],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"), right: memory.url("/B"), settings: MemorySettings())
    }

    func marked(_ model: PanelModel) -> [String] { model.items.filter { model.isSelected($0) }.map(\.name) }

    @Test func aGroupMarksBothTwins() {
        let bench = makeBench()
        bench.commands.perform(.selectGroup, .text("*.txt"))
        #expect(bench.left.model.selectionCount == 2)
        #expect(marked(bench.left.model).count == 2)
        bench.commands.perform(.unselectGroup, .text("*.txt"))
        #expect(bench.left.model.selectionCount == 0)
    }

    @Test func invertingTreatsTheTwinsApart() {
        let bench = makeBench()
        let model = bench.left.model
        model.setSelected(true, names: [composed])
        #expect(marked(model).map { isExactly($0, composed) } == [true])
        bench.commands.perform(SelectionCommands.invertFiles)
        let names = marked(model)
        #expect(names.count == 2 && names.contains { isExactly($0, decomposed) } && names.contains("plain.md"))
        #expect(!names.contains { isExactly($0, composed) })
    }

    @Test func aRuleAnswersPerEntry() {
        var type = SelectionType(name: "big")
        type.minSize = 2
        let items = memory.listing("/A")
        let names = SelectionRule(type).matching(among: items, base: memory.url("/A"))
        #expect(names.count == 1 && isExactly(names[0], composed))
        // The set a caller may still ask for holds one member for the twins that read alike.
        #expect(SelectionRule(mask: "*.txt").matching(among: items, base: memory.url("/A")).count == 2)
    }

    @Test func comparingKeepsTheTwinsApart() {
        let early = Date(timeIntervalSince1970: 1_000_000)
        func file(_ name: String) -> FileItem {
            FileItem(url: memory.url("/x/" + name), name: name, isDirectory: false, size: 1, modified: early)
        }
        let marks = DirectoryComparison.compare(
            left: [file(composed), file(decomposed)], right: [file(composed)], mode: .missing)
        #expect(marks.leftNames.count == 1 && isExactly(marks.leftNames[0], decomposed))
        #expect(marks.rightNames.isEmpty && marks.sameNames.count == 1 && isExactly(marks.sameNames[0], composed))
        // Only reading alike is enough where nothing is written exactly like it.
        let alike = DirectoryComparison.compare(left: [file(composed)], right: [file(decomposed)], mode: .missing)
        #expect(alike.leftNames.isEmpty && alike.rightNames.isEmpty)
    }

    @Test func aSelectionFileNamesTheTwinItWrites() {
        let bench = makeBench()
        pasteboard.clearContents()
        pasteboard.setString(decomposed + "\n", forType: .string)
        bench.commands.perform(SelectionCommands.loadSelectionFromClipboard)
        let names = marked(bench.left.model)
        #expect(names.count == 1 && isExactly(names[0], decomposed))
    }
}

extension MemoryFileSystem {
    fileprivate func listing(_ path: String) -> [FileItem] { (try? list(url(path), showHidden: true)) ?? [] }
}

// MARK: Multi-Rename

@MainActor @Suite struct ToolsAdoptMultiRename {
    @Test func theToolFollowsTheCapabilitiesOfTheFolderItIsIn() {
        let memory = MemoryFileSystem()
        memory.addFile("/open/a.txt")
        memory.addFile("/locked/b.txt")
        memory.capabilitiesAt = { $0.path.hasPrefix("/locked") ? [] : [.write] }
        let bench = TestBench(
            plugins: [MultiRenamePlugin(opensWindows: false)], fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/open"), right: memory.url("/locked"), settings: MemorySettings())
        bench.left.model.selectAll()
        bench.right.model.selectAll()
        #expect(bench.commands.isEnabled(.multiRename))
        bench.right.focus()
        #expect(!bench.commands.isEnabled(.multiRename))
    }
}

// MARK: Find Files

@Suite struct ToolsAdoptFindFiles {
    let fileSystems: FileSystemRegistry
    let memory: MemoryFileSystem

    init() {
        (fileSystems, memory) = makeFileSystems()
        memory.addFile("/D/top.txt")
        memory.addFile("/D/sub/s.txt")
        memory.addFile("/D/sub/deep/x.txt")
    }

    func find(_ query: SearchQuery, in fileSystems: FileSystemRegistry? = nil) -> [String] {
        var found: [String] = []
        FileSearch(query, fileSystems: fileSystems ?? self.fileSystems).run { found.append($0.url.path) }
        return found
    }

    @Test func aFileListedBesideItsFolderIsFoundOnce() {
        var query = SearchQuery(directory: memory.url("/D"), names: "*.txt")
        query.onlyItems = [
            memory.url("/D"), memory.url("/D/top.txt"), memory.url("/D/sub/s.txt"), memory.url("/D/sub/deep/x.txt")
        ]
        #expect(find(query).sorted() == ["/D/sub/deep/x.txt", "/D/sub/s.txt", "/D/top.txt"])
        // With a limit a deeper file may or may not be reached from the folder; either way once.
        for depth in 0...3 {
            query.maxDepth = depth
            let found = find(query)
            #expect(
                Set(found).count == found.count && found.contains("/D/top.txt") && found.contains("/D/sub/deep/x.txt"))
        }
    }

    @Test func nestedRootsKeptForTheirDepthReportEachFileOnce() throws {
        var query = SearchQuery(directory: memory.url("/D"), names: "*.txt", maxDepth: 1)
        query.moreDirectories = [memory.url("/D/sub")]
        #expect(find(query).sorted() == ["/D/sub/deep/x.txt", "/D/sub/s.txt", "/D/top.txt"])

        // On disk the nested folder may be claimed by the outer root first; the inner root still gets its deeper reach.
        let box = try Sandbox()
        try box.file("top.txt", "t")
        try box.file("sub/s.txt", "s")
        try box.file("sub/deep/x.txt", "x")
        var local = SearchQuery(directory: box.url("."), names: "*.txt", maxDepth: 1)
        local.moreDirectories = [box.url("sub")]
        for _ in 0..<20 {
            let found = find(local).map { URL(fileURLWithPath: $0).lastPathComponent }
            #expect(found.sorted() == ["s.txt", "top.txt", "x.txt"])
        }
    }

    @Test func hardLinkedFilesOfOverlappingRootsAreOneResult() throws {
        let box = try Sandbox()
        try box.file("one/a.txt", "a")
        var query = SearchQuery(directory: box.url("one"), names: "*.txt")
        query.onlyItems = [box.url("one"), box.url("one/a.txt")]
        #expect(find(query).count == 1)
    }

    @Test func cancellingEndsABlockedListing() {
        let probe = ProbingFileSystem(memory)
        let registry = FileSystemRegistry()
        registry.register(probe)
        memory.stallsListings = true
        defer { memory.releaseStalls() }
        let search = FileSearch(SearchQuery(directory: memory.url("/D")), fileSystems: registry)
        let done = background { search.run { _ in } }
        #expect(probe.listing.wait(timeout: .now() + adoptWait) == .success)
        cancelFromThread(search.cancellation)
        #expect(done.wait(timeout: .now() + adoptWait) == .success)
    }

    @Test func cancellingEndsABlockedContentRead() {
        let probe = ProbingFileSystem(memory)
        let registry = FileSystemRegistry()
        registry.register(probe)
        memory.stallsReads = true
        defer { memory.releaseStalls() }
        let search = FileSearch(SearchQuery(directory: memory.url("/D"), text: "needle"), fileSystems: registry)
        let done = background { search.run { _ in } }
        #expect(probe.reading.wait(timeout: .now() + adoptWait) == .success)
        cancelFromThread(search.cancellation)
        #expect(done.wait(timeout: .now() + adoptWait) == .success)
        #expect(memory.interruptions >= 1)
    }

    @Test func cancellingEndsABlockedDuplicateHash() {
        memory.addFile("/E/a", "same")
        memory.addFile("/E/b", "same")
        let probe = ProbingFileSystem(memory)
        let registry = FileSystemRegistry()
        registry.register(probe)
        memory.stallsReads = true
        defer { memory.releaseStalls() }
        let flag = CancellationFlag()
        let items = ["a", "b"].map { memory.item(at: memory.url("/E/" + $0))! }
        let groups = Outcome<[[FileItem]]>()
        let done = background {
            groups.value = DuplicateFinder.groups(
                of: items,
                options: DuplicateOptions(isEnabled: true, sameName: false, sameSize: true, sameContents: true),
                fileSystems: registry, cancellation: flag)
        }
        #expect(probe.reading.wait(timeout: .now() + adoptWait) == .success)
        cancelFromThread(flag)
        #expect(done.wait(timeout: .now() + adoptWait) == .success)
        #expect(groups.value?.isEmpty == true)
    }

    @Test func specialItemsAreNotHashed() {
        let special = FileItem(
            url: memory.url("/D/top.txt"), name: "top.txt", isDirectory: false, size: 1, isSpecial: true)
        let plain = memory.item(at: memory.url("/D/sub/s.txt"))!
        let groups = DuplicateFinder.groups(
            of: [special, plain],
            options: DuplicateOptions(isEnabled: true, sameName: false, sameSize: true, sameContents: true),
            fileSystems: fileSystems)
        #expect(groups.isEmpty)
    }
}

// MARK: Directory Sync

@Suite struct ToolsAdoptDirectorySync {
    let early = Date(timeIntervalSince1970: 1_000_000)

    func registry(_ providers: any FileSystemProvider...) -> FileSystemRegistry {
        let registry = FileSystemRegistry()
        providers.forEach(registry.register)
        return registry
    }

    /// The order is the kernel's, with digits by value. (It was Foundation's localized
    /// comparison, which is no order and ends the program for certain names; for plain names
    /// the two agree, which the second half checks.)
    @Test func theWalkOrdersNamesAsTheSystemDoes() {
        var state: UInt64 = 7
        let alphabet = Array("aAbBzZ0019_.- \u{e9}(")
        func name() -> String {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            var rest = state >> 20
            return String(
                (0..<Int(1 + state % 9)).map { _ in
                    defer { rest = rest &* 31 &+ 17 }
                    return alphabet[Int((rest >> 5) % UInt64(alphabet.count))]
                })
        }
        let memory = MemoryFileSystem()
        let pairs = (0..<3_000).map { index -> SyncComparison.Pair in
            let text = name()
            return SyncComparison.Pair(
                left: FileItem(url: memory.url("/" + String(index)), name: text, isDirectory: false), right: nil)
        }
        let ordered = SyncComparison.sorted(pairs).map { $0.left!.name }
        for (one, two) in zip(ordered, ordered.dropFirst()) {
            #expect(Sorter.compare(one, two, numeric: true) != .orderedDescending)
        }
        #expect(ordered.count == pairs.count)
        // Names of letters and digits stand as the system has them: without regard to case, numbers by value.
        let plain = ["file10.txt", "File2.txt", "file1.txt", "b", "A", "a10", "a9", "Zebra", "apple"]
        let walked = SyncComparison.sorted(
            plain.enumerated().map { index, text in
                SyncComparison.Pair(
                    left: FileItem(url: memory.url("/p" + String(index)), name: text, isDirectory: false), right: nil)
            }
        ).map { $0.left!.name }
        #expect(walked == ["A", "a9", "a10", "apple", "b", "file1.txt", "File2.txt", "file10.txt", "Zebra"])
        for (one, two) in zip(walked, walked.dropFirst()) {
            #expect(one.localizedStandardCompare(two) != .orderedDescending)
        }
    }

    @Test func cancellingEndsABlockedListing() {
        let memory = MemoryFileSystem()
        memory.addFile("/L/a")
        memory.addFile("/R/a")
        let probe = ProbingFileSystem(memory)
        memory.stallsListings = true
        defer { memory.releaseStalls() }
        let comparison = SyncComparison(options: SyncOptions(), fileSystems: registry(probe))
        let result = Outcome<SyncResult>()
        let done = background { result.value = comparison.run(left: memory.url("/L"), right: memory.url("/R")) }
        #expect(probe.listing.wait(timeout: .now() + adoptWait) == .success)
        cancelFromThread(comparison.cancellation)
        #expect(done.wait(timeout: .now() + adoptWait) == .success)
        #expect(result.value?.wasCancelled == true && result.value?.errors.isEmpty == true)
    }

    @Test func cancellingEndsABlockedComparisonByContent() {
        let memory = MemoryFileSystem()
        memory.addFile("/L/a", "same", modified: early)
        memory.addFile("/R/a", "same", modified: early)
        let probe = ProbingFileSystem(memory)
        memory.stallsReads = true
        defer { memory.releaseStalls() }
        var options = SyncOptions()
        options.byContent = true
        let comparison = SyncComparison(options: options, fileSystems: registry(probe))
        let result = Outcome<SyncResult>()
        let done = background { result.value = comparison.run(left: memory.url("/L"), right: memory.url("/R")) }
        #expect(probe.reading.wait(timeout: .now() + adoptWait) == .success)
        cancelFromThread(comparison.cancellation)
        #expect(done.wait(timeout: .now() + adoptWait) == .success)
        #expect(result.value?.wasCancelled == true && result.value?.errors.isEmpty == true && memory.interruptions >= 1)
    }

    @Test func cancellingEndsABlockedCopy() {
        let memory = MemoryFileSystem()
        memory.refusesInternalCopy = true
        memory.addFile("/L/new.txt", "data", modified: early)
        memory.addDirectory("/R")
        let probe = ProbingFileSystem(memory)
        let registry = registry(probe)
        let plan = SyncPlan(
            rows: SyncComparison(options: SyncOptions(), fileSystems: registry).run(
                left: memory.url("/L"), right: memory.url("/R")
            ).rows)
        #expect(plan.toRight.count == 1)
        memory.stallsReads = true
        defer { memory.releaseStalls() }
        let flag = CancellationFlag()
        let executor = SyncExecutor(plan: plan, options: SyncRunOptions(), fileSystems: registry, cancellation: flag)
        let outcome = Outcome<SyncOutcome>()
        let done = background { outcome.value = executor.run() }
        #expect(probe.reading.wait(timeout: .now() + adoptWait) == .success)
        cancelFromThread(flag)
        #expect(done.wait(timeout: .now() + adoptWait) == .success)
        #expect(outcome.value?.wasCancelled == true && memory.interruptions >= 1)
        #expect(!memory.exists("/R/new.txt") && memory.allPaths.allSatisfy { !$0.contains("afm-sync") })
    }

    func syncSetup(deferred: Bool = true) -> (MemoryFileSystem, FileSystemRegistry) {
        let memory = MemoryFileSystem()
        memory.capabilities = deferred ? [.write, .deferredWrites] : [.write]
        memory.refusesInternalCopy = true
        memory.addFile("/L/new.txt", "from the left", modified: early.addingTimeInterval(500))
        memory.addDirectory("/L/folder")
        memory.addFile("/R/gone.txt", "only on the right", modified: early)
        return (memory, registry(memory))
    }

    func plan(_ memory: MemoryFileSystem, _ registry: FileSystemRegistry) -> SyncPlan {
        var options = SyncOptions()
        options.emptyDirectories = true
        var rows = SyncComparison(options: options, fileSystems: registry).run(
            left: memory.url("/L"), right: memory.url("/R")
        ).rows
        for index in rows.indices where rows[index].name == "gone.txt" { rows[index].action = .deleteRight }
        return SyncPlan(rows: rows)
    }

    @Test func copiesAreCommittedBeforeDeletions() {
        let (memory, registry) = syncSetup()
        memory.quarantineValue = Data("0081;5f;Safari;".utf8)
        memory.keepsMetadata = true
        let plan = plan(memory, registry)
        #expect(plan.toRight.count == 2 && plan.deleteRight.count == 1)
        var options = SyncRunOptions()
        options.useTrash = false
        let outcome = SyncExecutor(plan: plan, options: options, fileSystems: registry).run()
        #expect(outcome.errors.isEmpty && outcome.copied == 2 && outcome.deleted == 1)
        #expect(!memory.commits.isEmpty && memory.commits.allSatisfy { $0 == "/" })
        #expect(memory.exists("/R/new.txt") && !memory.exists("/R/gone.txt"))
        // A file that came from elsewhere keeps saying so; a created folder carries its metadata.
        // (A file on a file system that keeps writes back is written under a temporary name and renamed, so the
        // mark and the metadata are put on the temporary, as the provider's contract says.)
        #expect(memory.quarantineMarks.values.contains(Data("0081;5f;Safari;".utf8)))
        #expect(Set(memory.metadataCopies.map(\.to)) == ["/R/folder", "/R/.new.txt.afm-sync"])
    }

    @Test func aFailedCommitKeepsTheSources() {
        let (memory, registry) = syncSetup()
        struct Refused: Error {}
        memory.commitFailure = Refused()
        let outcome = SyncExecutor(plan: plan(memory, registry), options: SyncRunOptions(), fileSystems: registry).run()
        #expect(!outcome.errors.isEmpty && outcome.deleted == 0)
        #expect(memory.exists("/R/gone.txt"))
    }

    @Test func noCommitWhereWritesAreNotDeferred() {
        let (memory, registry) = syncSetup(deferred: false)
        _ = SyncExecutor(plan: plan(memory, registry), options: SyncRunOptions(), fileSystems: registry).run()
        #expect(memory.commits.isEmpty)
    }

    @Test func trashIsAskedPerLocation() {
        let (memory, registry) = syncSetup(deferred: false)
        memory.capabilitiesAt = { _ in [.write, .trash] }
        let outcome = SyncExecutor(plan: plan(memory, registry), options: SyncRunOptions(), fileSystems: registry).run()
        // The memory file system has no Trash: asking for it fails, which shows the capability was consulted for the location.
        #expect(outcome.deleted == 0 && !outcome.errors.isEmpty)
    }
}

@MainActor @Suite struct ToolsAdoptSyncSession {
    @Test func theSelectionOfTwoPanelsKeepsTheTwins() {
        let memory = MemoryFileSystem()
        memory.addFile("/A/" + composed)
        memory.addFile("/A/" + decomposed)
        memory.addDirectory("/B")
        let bench = TestBench(
            plugins: [DirectorySyncPlugin(opensWindows: false)], fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"), right: memory.url("/B"), settings: MemorySettings())
        bench.left.model.setSelected(true, names: [decomposed])
        let session = SyncSession(kernel: bench.kernel)
        session.adopt(left: bench.left.model, right: bench.right.model, includeHidden: false)
        #expect(session.selectedNames.count == 1 && isExactly(session.selectedNames[0], decomposed))
    }
}

// MARK: Compare content

@Suite struct ToolsAdoptCompare {
    @Test func linesThatDifferOnlyInNormalisationAreEqual() {
        let options = DiffOptions()
        let nfc = TextLine("caf\u{e9} au lait")
        let nfd = TextLine("cafe\u{301} au lait")
        #expect(options.hash(nfc) == options.hash(nfd) && options.isSameKey(nfc, nfd))
        var exact = DiffOptions()
        exact.ignoreCase = false
        exact.ignoreRepeatedSpaces = false
        exact.ignoreLineEndings = false
        #expect(exact.hash(nfc) == exact.hash(nfd))
        let diff = TextDiff.compute(
            left: [nfc, TextLine("same"), TextLine("\u{c5}ngstr\u{f6}m")],
            right: [nfd, TextLine("same"), TextLine("A\u{30a}ngstro\u{308}m")], options: options)
        #expect(diff.isIdentical)
        // ASCII is hashed as it is, and a real difference still shows.
        #expect(options.hash(TextLine("Hello  world")) == options.hash(TextLine("hello world")))
        #expect(options.hash(TextLine("caf\u{e9}")) != options.hash(TextLine("cafe")))
        #expect(!TextDiff.compute(left: [nfc], right: [TextLine("cafe au lait")], options: options).isIdentical)
    }

    @Test func comparisonIgnoresNormalisationInFiles() {
        let memory = MemoryFileSystem()
        let registry = FileSystemRegistry()
        registry.register(memory)
        memory.addFile("/a.txt", "caf\u{e9}\nsame\n")
        memory.addFile("/b.txt", "cafe\u{301}\nsame\n")
        let result = CompareLoader.load(left: memory.url("/a.txt"), right: memory.url("/b.txt"), fileSystems: registry)
        if case .text(_, _, let diff, _) = result.content {
            #expect(diff.isIdentical)
        } else {
            Issue.record("not text")
        }
        #expect(!result.isIdentical)
    }

    @MainActor @Test func theChosenFilesAreTheMarkedTwins() {
        let memory = MemoryFileSystem()
        memory.addFile("/A/" + composed, "x")
        memory.addFile("/A/" + decomposed, "y")
        memory.addFile("/B/other.txt", "z")
        let bench = TestBench(
            plugins: [], fileSystems: [LocalFileSystem(), memory], left: memory.url("/A"), right: memory.url("/B"),
            settings: MemorySettings())
        bench.left.model.setSelected(true, names: [decomposed])
        bench.right.model.setSelected(true, names: ["other.txt"])
        let (left, right) = CompareOperands.choose(source: bench.left.model, target: bench.right.model)
        #expect(
            left.map { isExactly($0.lastPathComponent, decomposed) } == true && right?.lastPathComponent == "other.txt")
    }

    @Test func cancellingEndsABlockedLoad() {
        let memory = MemoryFileSystem()
        memory.addFile("/a.txt", "one\n")
        memory.addFile("/b.txt", "two\n")
        let probe = ProbingFileSystem(memory)
        let registry = FileSystemRegistry()
        registry.register(probe)
        memory.stallsReads = true
        defer { memory.releaseStalls() }
        let flag = CancellationFlag()
        let result = Outcome<ComparedFiles>()
        let done = background {
            result.value = CompareLoader.load(
                left: memory.url("/a.txt"), right: memory.url("/b.txt"), fileSystems: registry, cancellation: flag)
        }
        #expect(probe.reading.wait(timeout: .now() + adoptWait) == .success)
        cancelFromThread(flag)
        #expect(done.wait(timeout: .now() + adoptWait) == .success)
        #expect(result.value?.wasCancelled == true && result.value?.message == nil && memory.interruptions >= 1)
    }

    @Test func cancellingEndsABlockedIdentityCheck() {
        let memory = MemoryFileSystem()
        memory.isLocal = false
        memory.addFile("/a", String(repeating: "0123456789", count: 1_000))
        memory.addFile("/b", String(repeating: "0123456789", count: 1_000))
        let probe = ProbingFileSystem(memory)
        let registry = FileSystemRegistry()
        registry.register(probe)
        memory.stallsReads = true
        defer { memory.releaseStalls() }
        let flag = CancellationFlag()
        let done = background {
            _ = try? CompareLoader.identical(
                memory.url("/a"), memory.url("/b"), size: 10_000, fileSystems: registry, cancellation: flag)
        }
        #expect(probe.reading.wait(timeout: .now() + adoptWait) == .success)
        cancelFromThread(flag)
        #expect(done.wait(timeout: .now() + adoptWait) == .success)
    }
}

// MARK: File tools

@Suite struct ToolsAdoptFileTools {
    private func random(_ count: Int, seed: UInt64) -> Data {
        var state = seed
        return Data(
            (0..<count).map { _ in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return UInt8(truncatingIfNeeded: state >> 33)
            })
    }

    /// The first form of the two six-bit codecs, kept as the reference of the pointer loops.
    private enum Reference {
        static let xx = Array("+-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)

        static func character(_ value: UInt8, xx isXX: Bool) -> UInt8 {
            isXX ? xx[Int(value & 63)] : (value & 63 == 0 ? 96 : (value & 63) + 32)
        }

        static func value(_ character: UInt8, xx isXX: Bool) -> UInt8? {
            if isXX { return xx.firstIndex(of: character).map { UInt8($0) } }
            return (32...96).contains(character) ? (character - 32) & 63 : nil
        }

        static func encode(_ data: Data, xx: Bool) -> Data {
            var output: [UInt8] = []
            data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < input.count {
                    let count = min(45, input.count - offset)
                    output.append(character(UInt8(count), xx: xx))
                    for group in stride(from: 0, to: count, by: 3) {
                        func byte(_ index: Int) -> UInt8 { group + index < count ? input[offset + group + index] : 0 }
                        let (a, b, c) = (byte(0), byte(1), byte(2))
                        output.append(character(a >> 2, xx: xx))
                        output.append(character((a << 4 | b >> 4) & 63, xx: xx))
                        output.append(character((b << 2 | c >> 6) & 63, xx: xx))
                        output.append(character(c & 63, xx: xx))
                    }
                    output.append(13)
                    output.append(10)
                    offset += count
                }
            }
            return Data(output)
        }

        static func decode(_ line: ArraySlice<UInt8>, xx: Bool) -> [UInt8]? {
            guard let first = line.first, let count = value(first, xx: xx).map(Int.init) else { return nil }
            var values: [UInt8] = []
            for character in line.dropFirst() {
                guard let value = value(character, xx: xx) else { return nil }
                values.append(value)
            }
            let needed = (count + 2) / 3 * 4
            guard values.count >= needed || (!xx && values.count + 3 >= needed) else { return nil }
            while values.count < needed { values.append(0) }
            var bytes: [UInt8] = []
            for group in stride(from: 0, to: needed, by: 4) {
                bytes.append(values[group] << 2 | values[group + 1] >> 4)
                bytes.append(values[group + 1] << 4 | values[group + 2] >> 2)
                bytes.append(values[group + 2] << 6 | values[group + 3])
            }
            return Array(bytes.prefix(count))
        }
    }

    @Test func sixBitLoopsMatchTheFirstImplementation() {
        let lengths =
            [0, 1, 2, 3, 4, 43, 44, 45, 46, 47, 89, 90, 91, 92, 135, 1_000, 4_096, 65_537]
            + (0..<60).map { ($0 * 7_919) % 3_000 }
        for (index, length) in lengths.enumerated() {
            let data = random(length, seed: UInt64(index + 1))
            for xx in [false, true] {
                let encoded = SixBitText.encode(data, xx: xx)
                #expect(encoded == Reference.encode(data, xx: xx))
                let bytes = [UInt8](encoded)
                var start = 0
                var decoded: [UInt8] = []
                while start < bytes.count {
                    let end = bytes[start...].firstIndex(of: 13)!
                    let line = bytes[start..<end]
                    let one = SixBitText.decode(line, xx: xx)
                    #expect(
                        one == Reference.decode(line, xx: xx)
                            && SixBitText.decode(line, xx: !xx) == Reference.decode(line, xx: !xx))
                    decoded += one ?? []
                    start = end + 2
                }
                #expect(decoded == [UInt8](data))
            }
        }
        // Lines that are not lines of the format, cut short, or too long.
        var state: UInt64 = 99
        for _ in 0..<20_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let count = Int(state >> 40) % 90
            let line = ArraySlice(
                (0..<count).map { offset -> UInt8 in
                    UInt8(28 + Int(((state >> UInt64(offset % 40)) &+ UInt64(offset) &* 31) % 100))
                })
            for xx in [false, true] { #expect(SixBitText.decode(line, xx: xx) == Reference.decode(line, xx: xx)) }
        }
    }

    @Test func aDigestWithoutAMethodHintIsFoundInOnePassOverTheOthers() throws {
        let box = try Sandbox()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
        let data = random(3 << 20, seed: 5)
        try data.write(to: box.url("f.bin"))
        let run = ToolRun(fileSystems: fileSystems)
        func digest(_ method: ChecksumMethod) -> String {
            let hasher = method.makeHasher()
            hasher.update(data)
            return hasher.finish().hex
        }
        // Two other methods of the same length than the first candidate: the second pass hashes both.
        let candidates: [ChecksumMethod] = [.sha256, .sha3_256, .blake3]
        let wanted = digest(.blake3)
        let results = ChecksumRun.digests(of: [(box.url("f.bin"), candidates, wanted)], run: run)
        let found = try results[0].get()
        #expect(
            found.count == 3 && found[0].hex == digest(.sha256) && found[1].hex == digest(.sha3_256)
                && found[2].hex == wanted)
    }

    @Test func cancellingEndsABlockedHash() {
        let memory = MemoryFileSystem()
        memory.addFile("/h/a", "data")
        let probe = ProbingFileSystem(memory)
        let registry = FileSystemRegistry()
        registry.register(probe)
        memory.stallsReads = true
        defer { memory.releaseStalls() }
        let flag = CancellationFlag()
        let run = ToolRun(fileSystems: registry, cancellation: flag)
        let results = Outcome<[Result<[[UInt8]], any Error>]>()
        let done = background { results.value = ChecksumRun.digests(of: [(memory.url("/h/a"), [.sha1])], run: run) }
        #expect(probe.reading.wait(timeout: .now() + adoptWait) == .success)
        cancelFromThread(flag)
        #expect(done.wait(timeout: .now() + adoptWait) == .success)
        if case .failure(let error)? = results.value?.first {
            #expect((error as? ToolError) == .cancelled)
        } else {
            Issue.record("the hash did not fail")
        }
        #expect(memory.interruptions >= 1)
    }

    @Test func cancellingEndsABlockedSplit() {
        let memory = MemoryFileSystem()
        let source = memory.addFile("/s/big.bin", String(repeating: "x", count: 100))
        memory.addDirectory("/out")
        let probe = ProbingFileSystem(memory)
        let registry = FileSystemRegistry()
        registry.register(probe)
        memory.stallsReads = true
        defer { memory.releaseStalls() }
        let flag = CancellationFlag()
        let run = ToolRun(fileSystems: registry, cancellation: flag)
        let item = memory.item(at: source)!
        let error = Outcome<any Error>()
        let done = background {
            do { try Splitter.split(item, into: memory.url("/out"), partSize: 40, run: run) } catch let thrown {
                error.value = thrown
            }
        }
        #expect(probe.reading.wait(timeout: .now() + adoptWait) == .success)
        cancelFromThread(flag)
        #expect(done.wait(timeout: .now() + adoptWait) == .success)
        #expect((error.value as? ToolError) == .cancelled)
        #expect(memory.allPaths.filter { $0.hasPrefix("/out/") }.isEmpty)
    }

    @Test func cancellingEndsABlockedWrite() {
        let memory = MemoryFileSystem()
        let source = memory.addFile("/s/data.bin", String(repeating: "x", count: 100))
        memory.addDirectory("/out")
        let probe = ProbingFileSystem(memory)
        let registry = FileSystemRegistry()
        registry.register(probe)
        memory.stallsWrites = true
        defer { memory.releaseStalls() }
        let flag = CancellationFlag()
        let run = ToolRun(fileSystems: registry, cancellation: flag)
        let item = memory.item(at: source)!
        let error = Outcome<any Error>()
        let done = background {
            do { try Encoder.encode(item, into: memory.url("/out"), method: .uue, run: run) } catch let thrown {
                error.value = thrown
            }
        }
        #expect(probe.writing.wait(timeout: .now() + adoptWait) == .success)
        cancelFromThread(flag)
        #expect(done.wait(timeout: .now() + adoptWait) == .success)
        #expect((error.value as? ToolError) == .cancelled && memory.interruptions >= 1)
    }
}

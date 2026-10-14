import Foundation
import TestSupport
import Testing

@testable import AFMKernel

private let folder = URL(fileURLWithPath: "/review2/second")

private func file(_ name: String, size: Int64 = 1) -> FileItem {
    FileItem(url: folder.appendingPathComponent(name), name: name, isDirectory: false, size: size)
}

private func dir(_ name: String) -> FileItem {
    FileItem(url: folder.appendingPathComponent(name), name: name, isDirectory: true)
}

private func listing(_ items: [FileItem]) -> Listing {
    Listing(
        directory: folder, items: items, parent: folder.deletingLastPathComponent(), root: URL(fileURLWithPath: "/"))
}

private func panel(_ items: [FileItem], sort: ListOrder = ListOrder()) -> PanelModel {
    let model = PanelModel(directory: folder, sort: sort)
    model.show(listing(items))
    return model
}

/// Runs work on another thread and waits for it, as a panel does with long lists.
private func elsewhere<Value>(_ work: @escaping () -> Value) -> Value {
    let done = DispatchSemaphore(value: 0)
    var value: Value?
    Thread.detachNewThread {
        value = work()
        done.signal()
    }
    done.wait()
    return value!
}

/// A file system that knows its top and counts how often it is asked to go up.
private final class RootedFileSystem: FileSystemProvider {
    let scheme = "rooted"
    let capabilities: FileSystemCapabilities = []
    let knowsItsTop: Bool
    private let lock = NSLock()
    private var climbs = 0

    init(knowsItsTop: Bool) { self.knowsItsTop = knowsItsTop }

    var parentQuestions: Int {
        lock.lock()
        defer { lock.unlock() }
        return climbs
    }

    func list(_: URL, showHidden _: Bool) -> [FileItem] { [] }
    func item(at _: URL) -> FileItem? { nil }
    func parent(of directory: URL) -> URL? {
        lock.lock()
        climbs += 1
        lock.unlock()
        return directory.path == "/" ? nil : directory.deletingLastPathComponent()
    }
    func read(_: URL) throws -> FileReader { throw FileSystemError.notSupported("Reading") }
    func createDirectory(at _: URL) {}
    func write(_: URL) throws -> FileWriter { throw FileSystemError.notSupported("Writing") }
    func remove(_: URL) {}
    func move(_: URL, to _: URL, replacing _: Bool) {}
    func copy(_: URL, to _: URL, progress _: (Int64) -> Bool) {}

    func root(of url: URL) -> URL {
        guard knowsItsTop else {
            // What the kernel does for a file system that does not say: it goes up.
            var current = url
            while let parent = parent(of: current) { current = parent }
            return current
        }
        return URL(string: "rooted:///")!
    }
}

/// The second pass of review 2: what was still open in the kernel after the first.
@MainActor @Suite struct Review2KernelP2 {
    // MARK: K047 — the order the files came in

    @Test func theModelSaysWhetherItsListIsStillInTheOrderItCameIn() {
        let came = [file("m.txt"), file("a.txt"), file("z.txt")]
        let unsorted = ListOrder(key: .unsorted)
        let model = panel(came, sort: unsorted)
        #expect(model.isInArrivalOrder && model.items.map(\.name) == ["m.txt", "a.txt", "z.txt"])
        // Another key puts the files in its order, and the order they came in is gone…
        model.setSort(ListOrder(key: .name))
        #expect(!model.isInArrivalOrder && model.items.map(\.name) == ["a.txt", "m.txt", "z.txt"])
        // …so that choosing Unsorted again leaves them as they are, and the model says so:
        model.setSort(unsorted)
        #expect(!model.isInArrivalOrder && model.items.map(\.name) == ["a.txt", "m.txt", "z.txt"])
        // whoever wants the old order reads the directory again, which brings it back.
        model.update(with: listing(came))
        #expect(model.isInArrivalOrder && model.items.map(\.name) == ["m.txt", "a.txt", "z.txt"])
    }

    @Test func theOrderOfArrivalIsFollowedThroughEveryWayAListChanges() {
        let came = [file("m.txt"), file("a.txt"), file("z.txt")]
        let (unsorted, byName) = (ListOrder(key: .unsorted), ListOrder(key: .name))
        // Shown sorted by a key: never in the order of arrival.
        let sorted = panel(came, sort: byName)
        #expect(!sorted.isInArrivalOrder)
        // The background route says the same as the direct one.
        let model = panel(came, sort: unsorted)
        let basis = model.basis
        let prepared = elsewhere { PanelModel.prepare(basis, sort: byName) }
        #expect(model.apply(prepared) == .changed && !model.isInArrivalOrder)
        // A snapshot remembers it, a copy takes it along, and a new folder starts afresh.
        let fresh = panel(came, sort: unsorted)
        let before = fresh.snapshot()
        fresh.setSort(byName)
        #expect(!fresh.isInArrivalOrder && !fresh.duplicate().isInArrivalOrder)
        fresh.open(URL(fileURLWithPath: "/review2/other"), parent: folder, root: URL(fileURLWithPath: "/"))
        #expect(fresh.isInArrivalOrder)
        fresh.restore(before)
        // The panel's order is by name now, so the restored list was sorted, too.
        #expect(!fresh.isInArrivalOrder && fresh.items.map(\.name) == ["a.txt", "m.txt", "z.txt"])
        // A directory that arrives in pieces while the order is Unsorted stays as it came.
        let arriving = PanelModel(directory: folder, sort: unsorted)
        arriving.show(listing([came[0]]), complete: false)
        arriving.extend(to: came, sortedBy: unsorted)
        #expect(arriving.isInArrivalOrder && arriving.items.map(\.name) == ["m.txt", "a.txt", "z.txt"])
    }

    // MARK: K033 — calculated sizes without the copy on the main thread

    @Test func calculatedSizesCanBePreparedInTheBackground() {
        let items = (0..<300).map { $0 % 3 == 0 ? dir("dir\($0)") : file("file\($0).txt", size: Int64($0)) }
        for filtered in [false, true] {
            let (model, plain) = (panel(items), panel(items))
            if filtered {
                let filter = PanelFilter(title: "some") { $0.isFolder ? $0.name.hasSuffix("0") : true }
                model.setFilter(filter)
                plain.setFilter(filter)
            }
            model.setSelected(true, names: ["dir30", "file1.txt"])
            plain.setSelected(true, names: ["dir30", "file1.txt"])
            model.moveCursor(to: 7)
            plain.moveCursor(to: 7)
            let sizes: [(name: String, size: Int64)] = [
                ("dir0", 1_000), ("dir30", 500), ("dir3", 70), ("nobody", 9)
            ]
            // The basis holds the list as well: the copy is made where `prepare` runs.
            let basis = model.basis
            let (version, shown) = (model.listVersion, model.shownVersion)
            let prepared = elsewhere { PanelModel.prepare(basis, computedSizes: sizes) }
            var announced: [PanelModel.Change] = []
            model.onChange = { announced.append($0) }
            #expect(model.apply(prepared) == .changed)
            plain.setComputedSizes(sizes)
            // Exactly what the direct call gives: sizes in both lists, totals, marks, cursor.
            #expect(model.items == plain.items && model.listedItems == plain.listedItems)
            #expect(
                model.totals == plain.totals && model.selectedNames == plain.selectedNames
                    && model.cursor == plain.cursor)
            #expect(model.listedItems.first { $0.name == "dir3" }?.computedSize == 70)
            // The list is not another list for it.
            #expect(model.listVersion == version && model.shownVersion == shown && announced.count == 1)
            // A size set later, by either route, lands on top of these.
            plain.setComputedSize(11, forName: "dir6")
            model.setComputedSize(11, forName: "dir6")
            #expect(model.listedItems == plain.listedItems && model.totals == plain.totals)
        }
    }

    @Test func preparedSizesAreRefusedWhenAnythingTheyRestOnHasChanged() {
        let items = (0..<50).map { dir("dir\($0)") }
        let model = panel(items)
        // Another size was set meanwhile: taking the prepared list would lose it.
        var prepared = PanelModel.prepare(model.basis, computedSizes: [(name: "dir1", size: 10)])
        model.setComputedSize(5, forName: "dir2")
        #expect(model.apply(prepared) == .stale)
        #expect(
            model.listedItems.first { $0.name == "dir2" }?.computedSize == 5
                && model.listedItems.first { $0.name == "dir1" }?.computedSize == nil)
        // Prepared again from the model as it is now, both are there.
        prepared = PanelModel.prepare(model.basis, computedSizes: [(name: "dir1", size: 10)])
        #expect(model.apply(prepared) == .changed)
        #expect(
            model.listedItems.first { $0.name == "dir2" }?.computedSize == 5
                && model.listedItems.first { $0.name == "dir1" }?.computedSize == 10)
        // The list changed meanwhile.
        prepared = PanelModel.prepare(model.basis, computedSizes: [(name: "dir3", size: 1)])
        model.setSort(ListOrder(key: .name, descending: true))
        #expect(model.apply(prepared) == .stale)
        // No name was found: nothing to do, and the model says so.
        prepared = PanelModel.prepare(model.basis, computedSizes: [(name: "nobody", size: 1)])
        #expect(model.apply(prepared) == .unchanged)
        // The sizes survive a sort that was prepared before they were set.
        let basis = model.basis
        let sorted = PanelModel.prepare(basis, sort: ListOrder(key: .name))
        #expect(model.apply(PanelModel.prepare(model.basis, computedSizes: [(name: "dir7", size: 77)])) == .changed)
        #expect(model.apply(sorted) == .changed)
        #expect(
            model.listedItems.first { $0.name == "dir7" }?.computedSize == 77
                && model.listedItems.first { $0.name == "dir1" }?.computedSize == 10)
    }

    @Test func aNameWrittenInAnotherFormFindsItsFolderWhenSizesArePrepared() {
        // `é` as one character in the list, as `e` and an accent in the question.
        let model = panel([dir("caf\u{E9}"), dir("plain")])
        let prepared = PanelModel.prepare(model.basis, computedSizes: [(name: "cafe\u{301}", size: 42)])
        #expect(
            model.apply(prepared) == .changed
                && model.listedItems.first { $0.name.hasPrefix("caf") }?.computedSize == 42)
    }

    // MARK: S011 — is a file among the operands?

    @Test func whetherAFileIsMarkedIsAnsweredFromMemoryUntilTheMarksChange() {
        let items = (0..<200).map { dir("dir\($0)") } + [file("only.txt"), file("other.txt")]
        let model = panel(items)
        model.select(where: { $0.isFolder })
        #expect(model.selectionCount == 200 && !model.hasOperandFile && !model.hasOperandFile)
        // Every way the marks change is seen.
        model.setSelected(true, names: ["only.txt"])
        #expect(model.hasOperandFile)
        model.setSelected(false, names: ["only.txt"])
        #expect(!model.hasOperandFile)
        model.selectAll()
        #expect(model.hasOperandFile)
        model.invertSelection()
        #expect(!model.hasSelection)
        // Without marks the cursor decides, wherever it goes.
        model.moveCursor(to: model.row(ofName: "only.txt")!)
        #expect(model.hasOperandFile)
        model.moveCursor(to: model.row(ofName: "dir3")!)
        #expect(!model.hasOperandFile)
        // A fresh reading in which a marked folder has become a file.
        model.select(where: { $0.name == "dir5" })
        #expect(!model.hasOperandFile)
        var changed = items
        changed[5] = file("dir5")
        model.update(with: listing(changed))
        #expect(model.isSelected(changed[5]) && model.hasOperandFile)
        // A filter that hides the only marked file takes its mark, and the answer with it.
        model.clearSelection()
        model.setSelected(true, names: ["other.txt", "dir9"])
        #expect(model.hasOperandFile)
        model.setFilter(PanelFilter(title: "folders") { $0.isFolder })
        #expect(!model.hasOperandFile && model.selectionCount == 1)
    }

    // MARK: Restoring a long saved selection

    @Test func aLongSavedSelectionIsRestoredInAnotherFolderOfTheSameNames() {
        let count = 60_000
        let items = (0..<count).map { file("f\($0).dat", size: Int64($0 % 7)) }
        let model = panel(items)
        // More than the model keeps as names: the list itself is kept for the saved marks.
        model.select(where: { $0.size != 0 })
        let marked = model.selectionCount
        #expect(marked > 30_000)
        model.saveSelection()
        // Another folder with most of the names, some gone, some new, in another order.
        let other = URL(fileURLWithPath: "/review2/elsewhere")
        let there =
            (0..<count).reversed().compactMap { index -> FileItem? in
                index % 11 == 0
                    ? nil
                    : FileItem(
                        url: other.appendingPathComponent("f\(index).dat"), name: "f\(index).dat", isDirectory: false,
                        size: 3)
            } + [FileItem(url: other.appendingPathComponent("new.dat"), name: "new.dat", isDirectory: false)]
        model.show(Listing(directory: other, items: there, parent: folder, root: URL(fileURLWithPath: "/")))
        #expect(!model.hasSelection)
        model.restoreSelection()
        let expected = Set((0..<count).filter { $0 % 7 != 0 && $0 % 11 != 0 }.map { "f\($0).dat" })
        #expect(model.selectionCount == expected.count && Set(model.selectedNames) == expected)
        // With a filter on, only what is shown is marked.
        model.setFilter(PanelFilter(title: "ones") { $0.name.hasSuffix("1.dat") })
        model.restoreSelection()
        #expect(Set(model.selectedNames) == expected.filter { $0.hasSuffix("1.dat") })
    }

    // MARK: K039 — the top of the tree

    @Test func aFileSystemThatKnowsItsTopIsNotClimbed() throws {
        let deep = "/" + (0..<400).map { "d\($0)" }.joined(separator: "/")
        for knows in [true, false] {
            let provider = RootedFileSystem(knowsItsTop: knows)
            let fileSystems = FileSystemRegistry()
            fileSystems.register(provider)
            let location = URL(string: "rooted://" + deep)!
            let result = try PanelLoader.load(location, showHidden: false, fileSystems: fileSystems)
            #expect(
                result.listing.root.path == "/"
                    && result.listing.parent?.path == (deep as NSString).deletingLastPathComponent)
            // One question for the directory above; the top is asked of the file system.
            if knows { #expect(provider.parentQuestions == 1) } else { #expect(provider.parentQuestions >= 400) }
        }
    }

    @Test func theTopIsFoundByGoingUpWhereAFileSystemDoesNotSay() {
        let memory = MemoryFileSystem()
        #expect(memory.root(of: memory.url("/a/b/c")).path == "/")
        // Through the protocol, which is how the loader asks.
        let provider: FileSystemProvider = memory
        #expect(provider.root(of: memory.url("/a/b/c")).isSameLocation(as: memory.url("/")))
    }

    // MARK: Calls with a flag

    @Test func aCopyWithAFlagStopsWhenTheFlagIsSetAndSaysSo() throws {
        let memory = MemoryFileSystem()
        memory.copyBlockSize = 4
        memory.addFile("/a.bin", String(repeating: "x", count: 64))
        // The kernel's own default, which a file system gets without doing anything.
        final class Plain: FileSystemProvider {
            let scheme = "plain"
            let capabilities: FileSystemCapabilities = [.write]
            let memory: MemoryFileSystem
            init(_ memory: MemoryFileSystem) { self.memory = memory }
            func list(_: URL, showHidden _: Bool) -> [FileItem] { [] }
            func item(at _: URL) -> FileItem? { nil }
            func parent(of _: URL) -> URL? { nil }
            func read(_: URL) throws -> FileReader { throw FileSystemError.notSupported("Reading") }
            func createDirectory(at _: URL) {}
            func write(_: URL) throws -> FileWriter { throw FileSystemError.notSupported("Writing") }
            func remove(_: URL) {}
            func move(_: URL, to _: URL, replacing _: Bool) {}
            func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
                try memory.copy(memory.url(source.path), to: memory.url(destination.path), progress: progress)
            }
        }
        let provider: FileSystemProvider = Plain(memory)
        let (from, to) = (URL(string: "plain:///a.bin")!, URL(string: "plain:///b.bin")!)
        // Set before the call: nothing is begun.
        let set = CancellationFlag()
        set.cancel()
        var asked = 0
        #expect(throws: CocoaError.self) {
            try provider.copy(from, to: to, cancellation: set) { _ in
                asked += 1
                return true
            }
        }
        #expect(asked == 0 && !memory.exists("/b.bin"))
        // Set while it runs, by somebody other than `progress`: the copy stops at the next block.
        let flag = CancellationFlag()
        var reports: [Int64] = []
        #expect(throws: CocoaError.self) {
            try provider.copy(from, to: to, cancellation: flag) { copied in
                reports.append(copied)
                if copied == 12 { flag.cancel() }
                return true
            }
        }
        #expect(reports == [4, 8, 12] && !memory.exists("/b.bin"))
        // Left alone, it copies.
        try provider.copy(from, to: to, cancellation: CancellationFlag()) { _ in true }
        #expect(memory.contents("/b.bin")?.count == 64)
    }

    @Test func aFolderThatMustBeNewIsRefusedWhenSomethingHasItsName() throws {
        let memory = MemoryFileSystem()
        let provider: FileSystemProvider = memory
        try provider.createDirectory(at: memory.url("/new/inner"), exclusive: true, cancellation: CancellationFlag())
        #expect(memory.exists("/new/inner"))
        #expect(throws: FileSystemError.self) {
            try provider.createDirectory(
                at: memory.url("/new/inner"), exclusive: true, cancellation: CancellationFlag())
        }
        // Not exclusive: as before, with the flag passed on.
        try provider.createDirectory(at: memory.url("/new/inner"), exclusive: false, cancellation: CancellationFlag())
        #expect(memory.flaggedChanges == ["createDirectory /new/inner"])
        let set = CancellationFlag()
        set.cancel()
        #expect(throws: CocoaError.self) {
            try provider.createDirectory(at: memory.url("/other"), exclusive: true, cancellation: set)
        }
        #expect(!memory.exists("/other"))
    }

    // MARK: A sort that is asked for while the directory keeps arriving

    @Test func anOrderThatWasAskedForComesWithTheNextListThatArrives() {
        let came = [file("m.txt", size: 2), file("a.txt", size: 3), file("z.txt", size: 1)]
        let (byName, bySize) = (ListOrder(key: .name), ListOrder(key: .size))
        let model = panel(came, sort: byName)
        var announced = 0
        model.onChange = { _ in announced += 1 }
        let version = model.listVersion
        // Asking costs nothing and shows nothing.
        model.requestSort(bySize)
        #expect(model.requestedSort == bySize && model.wantedSort == bySize && model.sort == byName)
        #expect(
            announced == 0 && model.listVersion == version && model.items.map(\.name) == ["a.txt", "m.txt", "z.txt"])
        // A sort for the wanted order is made in the background; meanwhile the directory
        // changes, so the sort is stale…
        let sorted = elsewhere { [basis = model.basis] in PanelModel.prepare(basis, sort: bySize) }
        let fresh = came + [file("k.txt", size: 9)]
        let update = elsewhere { [basis = model.basis] in PanelModel.prepare(basis, update: listing(fresh)) }
        #expect(model.apply(update) == .changed)
        // …but the reading that arrived brought the order with it: nothing is left to race.
        #expect(model.sort == bySize && model.requestedSort == nil && model.wantedSort == bySize)
        #expect(model.items.map(\.name) == Sorter.sort(fresh, by: bySize).map(\.name))
        #expect(model.apply(sorted) == .stale)
        // The same through the calls that do everything at once, and for a list in pieces.
        model.requestSort(byName)
        model.update(with: listing(fresh + [file("b.txt")]))
        #expect(
            model.sort == byName && model.requestedSort == nil
                && model.items.map(\.name) == ["a.txt", "b.txt", "k.txt", "m.txt", "z.txt"])
        model.requestSort(bySize)
        model.extend(to: Sorter.sort(fresh, by: byName), sortedBy: byName)
        #expect(
            model.sort == bySize && model.requestedSort == nil
                && model.items.map(\.name) == Sorter.sort(fresh, by: bySize).map(\.name))
        model.requestSort(byName)
        let grown = elsewhere { [basis = model.basis] in
            PanelModel.prepare(basis, extendingTo: Sorter.sort(fresh, by: byName), sortedBy: byName)
        }
        #expect(model.apply(grown) == .changed && model.sort == byName && model.requestedSort == nil)
        // Another folder shown while an order is wanted is shown in it.
        model.requestSort(bySize)
        model.show(listing(came))
        #expect(
            model.sort == bySize && model.requestedSort == nil
                && model.items.map(\.name) == Sorter.sort(came, by: bySize).map(\.name))
    }

    @Test func aSortThatIsNoLongerTheOneAskedForIsRefused() {
        let came = (0..<40).map { file("f\($0).txt", size: Int64(40 - $0)) }
        let (byName, bySize, byDate) = (ListOrder(key: .name), ListOrder(key: .size), ListOrder(key: .date))
        let model = panel(came, sort: byName)
        // The user chooses one order and, before it is ready, another.
        model.requestSort(bySize)
        let first = PanelModel.prepare(model.basis, sort: bySize)
        model.requestSort(byDate)
        let second = PanelModel.prepare(model.basis, sort: byDate)
        #expect(model.apply(first) == .stale && model.sort == byName)
        #expect(model.apply(second) == .changed && model.sort == byDate && model.requestedSort == nil)
        // Asking for the order the list is in asks for nothing; so does sorting directly.
        model.requestSort(byDate)
        #expect(model.requestedSort == nil)
        model.requestSort(bySize)
        model.setSort(byName)
        #expect(model.requestedSort == nil && model.sort == byName)
        // A caller that never asks is served as before.
        #expect(model.apply(PanelModel.prepare(model.basis, sort: bySize)) == .changed && model.sort == bySize)
        // Preparing the order the list is in changes nothing in it.
        let before = model.items
        #expect(model.apply(PanelModel.prepare(model.basis, sort: bySize)) == .changed && model.items == before)
        // A snapshot taken before a request: going back puts the list into the wanted order.
        let snapshot = model.snapshot()
        model.open(URL(fileURLWithPath: "/review2/other"), parent: folder, root: URL(fileURLWithPath: "/"))
        model.requestSort(byName)
        model.restore(snapshot)
        #expect(
            model.sort == byName && model.requestedSort == nil
                && model.items.map(\.name) == Sorter.sort(came, by: byName).map(\.name))
    }

    // MARK: Rows by index

    @Test func rowsWorkedOutAsIndexesBecomeASelectionInOneStep() {
        let items = (0..<200).map { file("f\($0).txt", size: Int64($0)) }
        for filtered in [false, true] {
            let model = panel(items)
            if filtered { model.setFilter(PanelFilter(title: "even") { $0.size % 2 == 0 }) }
            let basis = model.basis
            // Every third shown row, as a command that pairs or counts rows finds them.
            let indices = Array(stride(from: 0, to: basis.items.count, by: 3))
            let rows = elsewhere { PanelModel.rows(of: basis, indices: indices + [-1, 1_000_000]) }
            #expect(rows.count == indices.count && model.setSelection(rows))
            #expect(model.selectedNames == indices.map { model.items[$0].name })
            // Added to and taken from what is marked, like any other set of rows.
            let more = PanelModel.rows(of: model.basis, indices: [1, 2])
            #expect(model.setSelection(more, .add) && model.selectionCount == indices.count + 2)
            #expect(model.setSelection(more, .remove) && model.selectionCount == indices.count)
            // Stale once what is shown has changed.
            model.setSort(ListOrder(key: .size, descending: true))
            #expect(!model.setSelection(rows))
        }
    }

    // MARK: A commit that reports

    @Test func aCommitAsksItsProgressOnceWhereAFileSystemSaysNoMore() throws {
        let memory = MemoryFileSystem()
        memory.addFile("/a.txt")
        let provider: FileSystemProvider = memory
        var reports: [(Int64, Int64)] = []
        try provider.commit(memory.url("/"), cancellation: CancellationFlag()) { done, total in
            reports.append((done, total))
            return true
        }
        #expect(reports.count == 1 && reports[0] == (0, 0) && memory.commits == ["/"])
        // Stopped by its progress, or by its flag: not committed.
        #expect(throws: CocoaError.self) {
            try provider.commit(memory.url("/"), cancellation: CancellationFlag()) { _, _ in false }
        }
        let set = CancellationFlag()
        set.cancel()
        #expect(throws: CocoaError.self) { try provider.commit(memory.url("/"), cancellation: set) { _, _ in true } }
        #expect(memory.commits == ["/"])
        // Deleting below a root is plain deleting where a file system knows no links.
        try provider.remove(memory.url("/a.txt"), below: memory.url("/"), cancellation: CancellationFlag())
        #expect(!memory.exists("/a.txt") && memory.flaggedChanges == ["remove below / /a.txt"])
        #expect(
            FileSystemCapabilities([.write, .removeOnly]).contains(.removeOnly)
                && !memory.capabilities.contains(.removeOnly))
    }

    // MARK: The fake file system the other areas test with

    @Test func theFakeHoldsChangesThatCameWithAFlagUntilItIsSetOrTheyAreLetGo() {
        let memory = MemoryFileSystem()
        memory.addFile("/a.txt", "a")
        memory.addFile("/b.txt", "b")
        memory.stallsChanges = true
        let flag = CancellationFlag()
        let ended = DispatchSemaphore(value: 0)
        var failure: Error?
        Thread.detachNewThread {
            do { try memory.remove(memory.url("/a.txt"), cancellation: flag) } catch { failure = error }
            ended.signal()
        }
        // Until the call really waits: a condition, not a length of time.
        while memory.stalledChanges == 0 { usleep(1_000) }
        #expect(memory.exists("/a.txt"))
        flag.cancel()
        ended.wait()
        #expect(
            (failure as? CocoaError)?.code == .userCancelled && memory.exists("/a.txt") && memory.stalledChanges == 0)
        // Let go, a held call goes on and does its work.
        let other = CancellationFlag()
        Thread.detachNewThread {
            try? memory.move(memory.url("/b.txt"), to: memory.url("/c.txt"), replacing: false, cancellation: other)
            ended.signal()
        }
        while memory.stalledChanges == 0 { usleep(1_000) }
        memory.releaseStalls()
        ended.wait()
        #expect(memory.exists("/c.txt") && !memory.exists("/b.txt"))
        #expect(memory.flaggedChanges == ["remove /a.txt", "move /b.txt"])
    }

    @Test func theFakeStallsOnlyTheListingsItIsToldToAndSaysWhenOneWaits() throws {
        let memory = MemoryFileSystem()
        memory.addFile("/dead/a.txt")
        memory.addFile("/alive/b.txt")
        memory.stallsListings = true
        memory.stalledPaths = ["/dead"]
        #expect(
            try memory.list(memory.url("/alive"), showHidden: true, cancellation: CancellationFlag()).map(\.name) == [
                "b.txt"
            ])
        let flag = CancellationFlag()
        let ended = DispatchSemaphore(value: 0)
        var names: [String]?
        Thread.detachNewThread {
            names = try? memory.list(memory.url("/dead"), showHidden: true, cancellation: flag).map(\.name)
            ended.signal()
        }
        while memory.stalledListings(of: "/dead") == 0 { usleep(1_000) }
        #expect(memory.stalledListings(of: "/alive") == 0)
        memory.releaseStalls()
        ended.wait()
        #expect(names == ["a.txt"] && memory.stalledListings(of: "/dead") == 0)
    }
}

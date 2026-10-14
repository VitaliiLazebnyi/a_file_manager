import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// A file system that offers only what it must: everything else is the kernel's default.
private final class PlainFileSystem: FileSystemProvider {
    let inner = MemoryFileSystem(scheme: "plain")
    var scheme: String { inner.scheme }
    var capabilities: FileSystemCapabilities { [.write] }
    func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try inner.list(directory, showHidden: showHidden)
    }
    func item(at url: URL) -> FileItem? { inner.item(at: url) }
    func parent(of directory: URL) -> URL? { inner.parent(of: directory) }
    func read(_ url: URL) throws -> any FileReader { PlainReader(try inner.read(url)) }
    func createDirectory(at url: URL) throws { try inner.createDirectory(at: url) }
    func write(_ url: URL) throws -> any FileWriter { PlainWriter(try inner.write(url)) }
    func remove(_ url: URL) throws { try inner.remove(url) }
    func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try inner.move(source, to: destination, replacing: replacing)
    }
    func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try inner.copy(source, to: destination, progress: progress)
    }

    private final class PlainReader: FileReader {
        let inner: any FileReader
        init(_ inner: any FileReader) { self.inner = inner }
        func read(upToCount count: Int) throws -> Data? { try inner.read(upToCount: count) }
        func seek(to offset: UInt64) throws { try inner.seek(to: offset) }
        func close() { inner.close() }
    }

    private final class PlainWriter: FileWriter {
        let inner: any FileWriter
        init(_ inner: any FileWriter) { self.inner = inner }
        func write(_ data: Data) throws { try inner.write(data) }
        func close(attributes: FileAttributes) throws { try inner.close(attributes: attributes) }
    }
}

/// Something set on one thread and waited for on another, without a clock in between.
/// Unchecked: the value is guarded by `condition`.
private final class Signal<Value>: @unchecked Sendable {
    private let condition = NSCondition()
    private var value: Value?

    func set(_ value: Value) {
        condition.lock()
        self.value = value
        condition.broadcast()
        condition.unlock()
    }

    /// Nil only when nothing came for a very long time: a hang, reported as a failure.
    func wait(seconds: TimeInterval = 60) -> Value? {
        let end = Date(timeIntervalSinceNow: seconds)
        condition.lock()
        defer { condition.unlock() }
        while value == nil, condition.wait(until: end) {}
        return value
    }
}

private func waitUntil(seconds: TimeInterval = 60, _ condition: () -> Bool) -> Bool {
    let end = Date(timeIntervalSinceNow: seconds)
    while !condition() {
        if Date() > end { return false }
        Thread.sleep(forTimeInterval: 0.002)
    }
    return true
}

private func onThread(_ work: @escaping @Sendable () -> Void) {
    let thread = Thread(block: work)
    thread.stackSize = 1 << 20
    thread.start()
}

@Suite struct CancellationHandlers {
    @Test func aHandlerIsCalledOnceWhenTheFlagIsSet() {
        let flag = CancellationFlag()
        // The handlers run on this thread, inside the calls below.
        nonisolated(unsafe) var calls = 0
        let registration = flag.onCancel { calls += 1 }
        #expect(calls == 0 && !flag.isCancelled)
        flag.cancel()
        flag.cancel()
        #expect(calls == 1 && flag.isCancelled)
        _ = registration
        // A flag that is set already calls at once.
        // The handlers run on this thread, inside the calls below.
        nonisolated(unsafe) var late = 0
        let second = flag.onCancel { late += 1 }
        #expect(late == 1)
        _ = second
    }

    @Test func aReleasedRegistrationIsForgotten() {
        let flag = CancellationFlag()
        // The handlers run on this thread, inside the calls below.
        nonisolated(unsafe) var calls = 0
        var registration: AnyObject? = flag.onCancel { calls += 1 }
        let kept = flag.onCancel { calls += 10 }
        #expect(registration != nil)
        registration = nil
        flag.cancel()
        #expect(calls == 10)
        _ = kept
    }

    @Test func theFlagIsSetFromOtherThreadsWhileHandlersComeAndGo() {
        let flag = CancellationFlag()
        let counter = NSLock()
        // Guarded by `counter`.
        nonisolated(unsafe) var calls = 0
        let done = Signal<Bool>()
        onThread {
            Thread.sleep(forTimeInterval: 0.01)
            flag.cancel()
            done.set(true)
        }
        var registrations: [AnyObject] = []
        while !flag.isCancelled {
            registrations.append(
                flag.onCancel {
                    counter.lock()
                    calls += 1
                    counter.unlock()
                })
            if registrations.count > 64 { registrations.removeFirst(32) }
        }
        #expect(done.wait() == true)
        counter.lock()
        // Whatever was registered when the flag was set was called, each handler once.
        #expect(calls >= 1 && calls <= 65)
        counter.unlock()
    }
}

@Suite struct ProviderDefaults {
    private let plain = PlainFileSystem()

    @Test func whatAFileSystemDoesNotOfferBehavesAsBefore() throws {
        plain.inner.addFile("/a/one.txt", "12345")
        plain.inner.addDirectory("/a/sub")
        plain.inner.addFile("/a/.hidden")
        let directory = plain.inner.url("/a")
        let file = plain.inner.url("/a/one.txt")
        let flag = CancellationFlag()
        #expect(plain.capabilities(for: file) == [.write])
        #expect(try plain.list(directory, showHidden: false, cancellation: flag).map(\.name) == ["one.txt", "sub"])
        var streamed: [String] = []
        try plain.list(directory, showHidden: true, cancellation: flag) {
            streamed += $0.map(\.name)
            return true
        }
        #expect(streamed == [".hidden", "one.txt", "sub"])
        #expect(plain.item(at: file, cancellation: flag)?.size == 5)
        // The lean listing is made from the full one.
        #expect(
            try plain.entries(of: directory, showHidden: false, foldersOnly: false, cancellation: flag)
                == [
                    DirectoryEntry(name: "one.txt", isDirectory: false),
                    DirectoryEntry(name: "sub", isDirectory: true)
                ])
        #expect(
            try plain.entries(of: directory, showHidden: true, foldersOnly: true, cancellation: flag).map(\.name) == [
                "sub"
            ])
        // Readers and writers can be interrupted to no effect.
        let reader = try plain.read(file, cancellation: flag)
        reader.interrupt()
        #expect(try reader.read(upToCount: 10) == Data("12345".utf8))
        reader.close()
        let writer = try plain.write(plain.inner.url("/a/new.txt"), cancellation: flag)
        writer.interrupt()
        try writer.write(Data("new".utf8))
        try writer.close(attributes: FileAttributes())
        #expect(plain.inner.contents("/a/new.txt") == "new")
        // What is not offered says so, or does nothing.
        #expect(throws: FileSystemError.self) { try plain.append(to: file, at: 2) }
        #expect(throws: FileSystemError.self) { try plain.copyMetadata(from: directory, to: file) }
        try plain.commit(directory)
        #expect(plain.quarantine(of: file) == nil)
        try plain.setQuarantine(Data("0081;x".utf8), of: file)
    }

    @Test func aFlagThatIsSetEndsTheDefaultsEarly() throws {
        plain.inner.addFile("/a/one.txt")
        let directory = plain.inner.url("/a")
        let file = plain.inner.url("/a/one.txt")
        let flag = CancellationFlag()
        flag.cancel()
        var batches = 0
        try plain.list(directory, showHidden: true, cancellation: flag) { _ in
            batches += 1
            return true
        }
        #expect(batches == 0 && plain.item(at: file, cancellation: flag) == nil)
        #expect(throws: CocoaError.self) { try plain.read(file, cancellation: flag) }
        #expect(throws: CocoaError.self) { try plain.write(plain.inner.url("/a/two.txt"), cancellation: flag) }
        #expect(!plain.inner.exists("/a/two.txt"))
        #expect(plain.totalSize(of: directory, cancellation: flag) == 0)
    }

    @Test func capabilitiesAreAskedByLocation() {
        let memory = MemoryFileSystem()
        let registry = FileSystemRegistry()
        registry.register(memory)
        registry.register(plain)
        memory.capabilities = [.write, .trash]
        #expect(registry.capabilities(for: memory.url("/x")) == [.write, .trash])
        memory.capabilitiesAt = { $0.path.hasPrefix("/remote") ? [] : [.write, .append] }
        #expect(
            registry.capabilities(for: memory.url("/remote/x")) == []
                && registry.capabilities(for: memory.url("/here")) == [.write, .append])
        #expect(
            memory.capabilities == [.write, .trash] && registry.capabilities(for: plain.inner.url("/x")) == [.write])
        #expect(registry.capabilities(for: URL(string: "ftp://nowhere/x")!) == [])
    }
}

/// The in-memory file system stalls like a server that has stopped answering: what waits for
/// it must end when it is cancelled, and only then.
@Suite struct CancellingWhatWaits {
    private let memory = MemoryFileSystem()
    private let fileSystems = FileSystemRegistry()

    init() {
        memory.addFile("/far/a.txt", "abcdef")
        memory.addFile("/far/sub/b.txt", "xyz")
        fileSystems.register(memory)
    }

    @Test func aListingThatWaitsEndsWhenThePanelLoaderIsCancelled() {
        memory.stallsListings = true
        let flag = CancellationFlag()
        let ended = Signal<String>()
        // Written by the other thread before it signals, read here after the wait.
        nonisolated(unsafe) var batches = 0
        onThread { [memory, fileSystems] in
            do {
                _ = try PanelLoader.load(
                    memory.url("/far"), showHidden: false, fileSystems: fileSystems, cancellation: flag)
                ended.set("loaded")
            } catch let error as CocoaError where error.code == .userCancelled {
                ended.set("cancelled")
            } catch {
                ended.set("failed: \(error)")
            }
        }
        // The listing is under way and has nothing to say.
        #expect(waitUntil { memory.listRequests == ["/far"] })
        flag.cancel()
        #expect(ended.wait() == "cancelled")
        // Piece by piece it ends quietly, and nothing else is tried: no parent, no question about the item.
        let streamed = Signal<Bool>()
        let second = CancellationFlag()
        onThread { [memory, fileSystems] in
            try? PanelLoader.stream(
                memory.url("/far/sub"), showHidden: false, fileSystems: fileSystems, climbing: true,
                cancellation: second
            ) { _ in
                batches += 1
                return true
            }
            streamed.set(true)
        }
        #expect(waitUntil { memory.listRequests.count == 2 })
        second.cancel()
        #expect(streamed.wait() == true && batches == 0 && memory.listRequests == ["/far", "/far/sub"])
        // Without a flag, and with one that is never set, everything is as it was.
        memory.stallsListings = false
        #expect(
            (try? PanelLoader.load(memory.url("/far"), showHidden: false, fileSystems: fileSystems).listing.items.count)
                == 2)
        #expect(
            (try? PanelLoader.load(
                memory.url("/far/a.txt"), showHidden: false, fileSystems: fileSystems, cancellation: CancellationFlag()
            ).focus) == "a.txt")
    }

    @Test func aPausedListingStopsBetweenItsBatches() throws {
        for index in 0..<40 { memory.addFile("/many/f\(index).txt") }
        memory.listBatchSize = 10
        let flag = CancellationFlag()
        var received = 0
        try PanelLoader.stream(memory.url("/many"), showHidden: false, fileSystems: fileSystems, cancellation: flag) {
            batch in
            received += batch.listing.items.count
            flag.cancel()
            return true
        }
        #expect(received == 10)
        #expect(throws: CocoaError.self) {
            try PanelLoader.load(memory.url("/many"), showHidden: false, fileSystems: fileSystems, cancellation: flag)
        }
    }

    @Test func addingUpSizesEndsWhenAListingWaits() {
        memory.stallsListings = true
        let flag = CancellationFlag()
        let size = Signal<Int64>()
        onThread { [memory] in size.set(memory.totalSize(of: memory.url("/far"), cancellation: flag)) }
        // Until the listing really waits: a condition, not a length of time.
        #expect(waitUntil { memory.stalledListings(of: "/far") == 1 })
        flag.cancel()
        #expect(size.wait() == 0)
        memory.releaseStalls()
        #expect(memory.totalSize(of: memory.url("/far"), cancellation: CancellationFlag()) == 9)
    }

    @Test func aReadAndAWriteThatWaitAreInterruptedFromAnotherThread() throws {
        memory.stallsReads = true
        memory.stallsWrites = true
        let flag = CancellationFlag()
        let reader = try memory.read(memory.url("/far/a.txt"), cancellation: flag)
        let writer = try memory.write(memory.url("/far/new.txt"), cancellation: flag)
        let (read, written) = (Signal<String>(), Signal<String>())
        // What a transfer does: the flag interrupts both ends for as long as they are in use.
        let ties = [flag.interrupting(reader), flag.interrupting(writer)]
        onThread {
            do { read.set("read \(try reader.read(upToCount: 16)?.count ?? 0)") } catch { read.set("interrupted") }
        }
        onThread {
            do {
                try writer.write(Data("x".utf8))
                written.set("written")
            } catch { written.set("interrupted") }
        }
        Thread.sleep(forTimeInterval: 0.02)
        #expect(memory.interruptions == 0)
        flag.cancel()
        #expect(read.wait() == "interrupted" && written.wait() == "interrupted" && memory.interruptions == 2)
        // Interrupted stays interrupted, and interrupting again is harmless.
        reader.interrupt()
        #expect(throws: MemoryFileSystem.Interrupted.self) { try reader.read(upToCount: 1) }
        reader.close()
        #expect(ties.count == 2 && memory.interruptions == 2)
        // The tie does not keep a reader alive, and a released tie no longer interrupts.
        memory.stallsReads = false
        let other = CancellationFlag()
        var next: (any FileReader)? = try memory.read(memory.url("/far/a.txt"))
        weak let gone = next
        var tie: AnyObject? = other.interrupting(next!)
        next = nil
        #expect(gone == nil)
        let last = try memory.read(memory.url("/far/a.txt"))
        tie = other.interrupting(last)
        tie = nil
        other.cancel()
        #expect(try last.read(upToCount: 3) == Data("abc".utf8) && tie == nil)
    }
}

/// What the test file system itself offers of the new calls, for the plugins' tests.
@Suite struct MemoryFileSystemExtras {
    private let memory = MemoryFileSystem()

    @Test func aFileIsContinuedWhereItWasCut() throws {
        let file = memory.addFile("/part.bin", "0123456789")
        #expect(throws: FileSystemError.self) { try memory.append(to: file, at: 4) }
        memory.capabilities.insert(.append)
        let resumed = try memory.append(to: file, at: 4)
        #expect(memory.contents("/part.bin") == "0123")
        try resumed.write(Data("abc".utf8))
        try resumed.close(attributes: FileAttributes(modified: Date(timeIntervalSince1970: 5)))
        #expect(
            memory.contents("/part.bin") == "0123abc"
                && memory.item(at: file)?.modified == Date(timeIntervalSince1970: 5))
        let appended = try memory.append(to: file, at: nil)
        try appended.write(Data("!".utf8))
        try appended.close(attributes: FileAttributes())
        #expect(memory.contents("/part.bin") == "0123abc!")
        #expect(throws: FileSystemError.self) { try memory.append(to: file, at: 100) }
        #expect(throws: MemoryFileSystem.NotFound.self) { try memory.append(to: memory.url("/none"), at: 0) }
    }

    @Test func commitsMarksAndMetadataAreRecorded() throws {
        let file = memory.addFile("/in/a.txt")
        try memory.commit(memory.url("/in"))
        memory.commitFailure = FileSystemError.notSupported("Writing the archive")
        #expect(throws: FileSystemError.self) { try memory.commit(memory.url("/in")) }
        #expect(memory.commits == ["/in", "/in"])
        #expect(memory.quarantine(of: file) == nil)
        memory.quarantineValue = Data("0081;mark".utf8)
        #expect(memory.quarantine(of: file) == Data("0081;mark".utf8))
        try memory.setQuarantine(Data("0081;mark".utf8), of: file)
        #expect(memory.quarantineMarks == ["/in/a.txt": Data("0081;mark".utf8)])
        #expect(throws: FileSystemError.self) { try memory.copyMetadata(from: file, to: memory.url("/in")) }
        memory.keepsMetadata = true
        try memory.copyMetadata(from: file, to: memory.url("/in"))
        #expect(memory.metadataCopies.map(\.to) == ["/in"])
    }
}

@MainActor @Suite struct FilteringElsewhere {
    private let directory = URL(fileURLWithPath: "/work", isDirectory: true)

    private func model(_ items: [FileItem]) -> PanelModel {
        let model = PanelModel(directory: directory)
        model.show(
            Listing(
                directory: directory, items: items, parent: URL(fileURLWithPath: "/"), root: URL(fileURLWithPath: "/")
            )
        )
        return model
    }

    private func items(_ count: Int) -> [FileItem] {
        (0..<count).map { index in
            FileItem(
                url: directory.appending(name: "n\(index)"), name: index % 7 == 0 ? "dir\(index)" : "file\(index).txt",
                isDirectory: index % 7 == 0, size: Int64(index))
        }
    }

    private func isSame(_ a: PanelModel, _ b: PanelModel) -> Bool {
        a.items.map(\.name) == b.items.map(\.name) && a.listedItems.count == b.listedItems.count
            && a.selection == b.selection
            && a.selectionCount == b.selectionCount && a.cursor == b.cursor && a.cursorItem?.name == b.cursorItem?.name
            && a.totals == b.totals && a.filter?.title == b.filter?.title
    }

    @Test(arguments: [300, 40_000]) func aListFilteredElsewhereIsWhatSetFilterShows(count: Int) {
        let filter = PanelFilter(title: "3") { $0.isFolder || $0.name.contains("3") }
        let all = items(count)
        let (direct, handed) = (model(all), model(all))
        for model in [direct, handed] {
            model.setSelected(true, names: ["file3.txt", "file5.txt", "dir7", "file13.txt"])
            model.moveCursor(to: model.row(ofName: "file23.txt")!)
        }
        #expect(PanelModel.filtered(all, by: nil).count == count)
        let version = handed.listVersion
        var announced = 0
        handed.onChange = { if $0 == .contents { announced += 1 } }
        // Worked out on another thread, as a panel does it, and applied here.
        let done = Signal<[FileItem]>()
        let listed = handed.listedItems
        onThread { done.set(PanelModel.filtered(listed, by: filter)) }
        let shown = done.wait() ?? []
        #expect(handed.setFilter(filter, prefiltered: shown, listVersion: version))
        direct.setFilter(filter)
        // A filter is not another list: the version of the list stays.
        #expect(isSame(direct, handed) && announced == 1 && handed.listVersion == version)
        #expect(handed.selection == ["file3.txt", "dir7", "file13.txt"] && handed.cursorItem?.name == "file23.txt")
        // Taking the filter off again, the same way.
        let off = handed.listVersion
        #expect(
            handed.setFilter(nil, prefiltered: PanelModel.filtered(handed.listedItems, by: nil), listVersion: off))
        direct.setFilter(nil)
        #expect(isSame(direct, handed) && handed.items.count == count)
    }

    @Test func aListThatChangedMeanwhileIsFilteredHere() {
        let filter = PanelFilter(title: "1") { $0.name.contains("1") }
        let all = items(200)
        let (direct, handed) = (model(all), model(all))
        let version = handed.listVersion
        let stale = PanelModel.filtered(handed.listedItems, by: filter)
        // The directory was read again before the filtered list came back.
        let fresh = Listing(
            directory: directory, items: Array(all.dropFirst(20)), parent: URL(fileURLWithPath: "/"),
            root: URL(fileURLWithPath: "/"))
        handed.update(with: fresh)
        direct.update(with: fresh)
        #expect(!handed.setFilter(filter, prefiltered: stale, listVersion: version))
        direct.setFilter(filter)
        #expect(isSame(direct, handed) && handed.items.count < stale.count)
    }

    @Test func aNewVolumeFigureIsAnnounced() {
        let model = model(items(3))
        var changes = 0
        model.onChange = { _ in changes += 1 }
        model.setVolume(VolumeInfo(name: "Disk", freeBytes: 10, totalBytes: 20))
        model.setVolume(VolumeInfo(name: "Disk", freeBytes: 10, totalBytes: 20))
        #expect(changes == 1 && model.volume?.freeBytes == 10)
    }
}

/// Two entries whose names read the same and are written differently, as a server or a disk
/// from elsewhere can hold them: each is an entry of its own in everything the panel does.
@MainActor @Suite struct NamesThatReadTheSame {
    private let memory = MemoryFileSystem()
    private let fileSystems = FileSystemRegistry()
    private let composed = "caf\u{E9}", decomposed = "cafe\u{301}"

    init() {
        fileSystems.register(memory)
    }

    /// A folder with the two names as files (of two and three bytes) and as folders, among `others` plain files.
    private func panel(others: Int) throws -> PanelModel {
        memory.addFile("/d/\(composed).txt", "12")
        memory.addFile("/d/\(decomposed).txt", "123")
        memory.addDirectory("/d/\(composed)")
        memory.addDirectory("/d/\(decomposed)")
        for index in 0..<others { memory.addFile("/d/plain\(index).txt", "1234567") }
        let model = PanelModel(directory: memory.url("/d"))
        model.show(try PanelLoader.load(memory.url("/d"), showHidden: false, fileSystems: fileSystems).listing)
        return model
    }

    private func bytes(_ items: [FileItem]) -> [[UInt8]] { items.map { Array($0.name.utf8) } }
    private func row(_ model: PanelModel, _ name: String) -> Int {
        model.hasParentRow ? 1 + model.items.firstIndex { Array($0.name.utf8) == Array(name.utf8) }! : -1
    }

    @Test func theFileSystemKeepsBothAndTheyAreEqualAsStrings() throws {
        let model = try panel(others: 0)
        #expect(composed == decomposed && Array(composed.utf8) != Array(decomposed.utf8))
        #expect(model.items.count == 4 && Set(bytes(model.items)).count == 4 && Set(model.items.map(\.name)).count == 2)
        #expect(memory.contents("/d/\(composed).txt") == "12" && memory.contents("/d/\(decomposed).txt") == "123")
        #expect(
            memory.item(at: memory.url("/d/\(decomposed).txt")).map { Array($0.name.utf8) }
                == Array("\(decomposed).txt".utf8))
    }

    // A short list is walked; a long one is looked up through an index. Both must tell the two apart.
    @Test(arguments: [0, 200]) func aMarkOnOneIsNotAMarkOnTheOther(others: Int) throws {
        let model = try panel(others: others)
        let (one, two) = (row(model, "\(composed).txt"), row(model, "\(decomposed).txt"))
        #expect(
            one != two && model.row(ofName: "\(composed).txt") == one && model.row(ofName: "\(decomposed).txt") == two)
        model.toggleSelection(row: two)
        #expect(model.isSelected(row: two) && !model.isSelected(row: one) && model.selectionCount == 1)
        #expect(bytes(model.operands()) == [Array("\(decomposed).txt".utf8)] && model.operands().first?.size == 3)
        #expect(model.totals.selectedFiles == 1 && model.totals.selectedBytes == 3 && model.hasOperandFile)
        // The set of names cannot tell them apart; it says that something of that name is marked.
        #expect(model.selection == ["\(composed).txt"] && model.selection.count == 1)
        model.toggleSelection(row: one)
        #expect(
            model.selectionCount == 2 && model.selection.count == 1 && model.totals.selectedBytes == 5
                && model.operands().count == 2)
        model.toggleSelection(row: two)
        #expect(model.isSelected(row: one) && !model.isSelected(row: two) && model.operands().first?.size == 2)
        #expect(model.selection == ["\(decomposed).txt"] && model.totals.selectedBytes == 2)
        // Ranges, and every way of marking by name, go by the name as it is written.
        model.clearSelection()
        model.setSelected(true, rows: two...two)
        #expect(bytes(model.operands()) == [Array("\(decomposed).txt".utf8)])
        model.setSelected(false, names: ["\(composed).txt"])
        #expect(model.selectionCount == 1 && model.isSelected(row: two))
        model.setSelected(false, names: ["\(decomposed).txt"])
        #expect(model.selectionCount == 0)
        model.setSelected(true, names: ["\(composed).txt"])
        #expect(model.isSelected(row: one) && !model.isSelected(row: two))
        model.setSelection(names: ["\(decomposed).txt", decomposed])
        #expect(
            !model.isSelected(row: one) && model.isSelected(row: two) && model.isSelected(row: row(model, decomposed))
                && !model.isSelected(row: row(model, composed)) && model.selectionCount == 2
                && !model.operands().contains { $0.size == 2 })
        model.deselect([decomposed])
        #expect(model.selectionCount == 1 && model.isSelected(row: two))
        model.deselect(["\(composed).txt"])
        #expect(model.selectionCount == 1 && model.isSelected(row: two))
        // Everything, the opposite, a mask, and what was saved.
        model.invertSelection()
        #expect(
            model.selectionCount == model.items.count - 1 && !model.isSelected(row: two) && model.isSelected(row: one))
        model.saveSelection()
        model.selectAll()
        #expect(
            model.selectionCount == model.items.count && model.totals.selectedFiles == others + 2
                && model.totals.selectedFolders == 2)
        model.select(mask: "caf*.txt", select: false)
        #expect(model.selectionCount == model.items.count - 2)
        model.restoreSelection()
        #expect(model.selectionCount == model.items.count - 1 && !model.isSelected(row: two))
    }

    @Test(arguments: [0, 200]) func theMarkStaysOnItsEntryWhenTheListChanges(others: Int) throws {
        let model = try panel(others: others)
        model.toggleSelection(row: row(model, "\(decomposed).txt"))
        model.toggleSelection(row: row(model, composed))
        model.moveCursor(to: row(model, "\(decomposed).txt"))
        func isRight() -> Bool {
            model.selectionCount == 2
                && bytes(model.operands()) == [Array(composed.utf8), Array("\(decomposed).txt".utf8)]
                && model.cursorItem.map { Array($0.name.utf8) } == Array("\(decomposed).txt".utf8)
        }
        #expect(isRight())
        // Another order, a filter, a fresh reading, and a look back.
        model.setSort(ListOrder(key: .size, descending: true))
        #expect(isRight())
        model.setSort(ListOrder())
        model.setFilter(PanelFilter(title: "caf") { $0.name.hasPrefix("caf") })
        #expect(isRight() && model.items.count == 4)
        model.setFilter(nil)
        let snapshot = model.snapshot()
        memory.addFile("/d/zz-new.txt")
        #expect(
            model.update(
                with: try PanelLoader.load(memory.url("/d"), showHidden: false, fileSystems: fileSystems).listing))
        #expect(isRight() && model.items.count == others + 5)
        // The other spelling of a marked file goes away: its mark does not move over.
        try memory.remove(memory.url("/d/\(decomposed).txt"))
        model.update(with: try PanelLoader.load(memory.url("/d"), showHidden: false, fileSystems: fileSystems).listing)
        #expect(
            model.selectionCount == 1 && bytes(model.operands()) == [Array(composed.utf8)]
                && !model.isSelected(row: row(model, "\(composed).txt")))
        model.restore(snapshot)
        #expect(isRight())
    }

    @Test(arguments: [0, 200]) func aCalculatedSizeGoesToItsOwnFolder(others: Int) throws {
        let model = try panel(others: others)
        let (one, two) = (row(model, composed), row(model, decomposed))
        model.toggleSelection(row: two)
        model.setComputedSizes([(name: composed, size: 100), (name: decomposed, size: 7)])
        #expect(model.item(atRow: one)?.computedSize == 100 && model.item(atRow: two)?.computedSize == 7)
        #expect(model.totals.selectedBytes == 7 && model.totals.totalBytes == 107 + 5 + Int64(others) * 7)
        // By one name alone, the folder written like it.
        model.setComputedSize(9, forName: decomposed)
        #expect(
            model.item(atRow: one)?.computedSize == 100 && model.item(atRow: two)?.computedSize == 9
                && model.totals.selectedBytes == 9)
        // Under a filter the sizes go to both lists, and a fresh reading carries each over to its own.
        model.setFilter(PanelFilter(title: "folders") { $0.isFolder })
        model.setComputedSizes([(name: composed, size: 1), (name: decomposed, size: 2)])
        #expect(model.items.map(\.computedSize) == [1, 2] || model.items.map(\.computedSize) == [2, 1])
        model.setFilter(nil)
        model.update(with: try PanelLoader.load(memory.url("/d"), showHidden: false, fileSystems: fileSystems).listing)
        #expect(
            model.item(atRow: row(model, composed))?.computedSize == 1
                && model.item(atRow: row(model, decomposed))?.computedSize == 2)
        #expect(model.isSelected(row: row(model, decomposed)) && model.selectionCount == 1)
    }

    @Test func aNameWrittenDifferentlyStillFindsTheOnlyEntryThatReadsTheSame() throws {
        memory.addFile("/single/\(composed).txt")
        for index in 0..<100 { memory.addFile("/single/f\(index)") }
        let model = PanelModel(directory: memory.url("/single"))
        model.show(try PanelLoader.load(memory.url("/single"), showHidden: false, fileSystems: fileSystems).listing)
        // As before: where names are single, either writing means the one entry.
        for _ in 0..<4 { #expect(model.row(ofName: "\(decomposed).txt") == model.row(ofName: "\(composed).txt")) }
        model.setSelected(true, names: ["\(decomposed).txt"])
        #expect(
            model.selectionCount == 1 && model.operands().map(\.name) == ["\(composed).txt"]
                && model.selection.contains("\(decomposed).txt"))
        model.deselect(["\(decomposed).txt"])
        #expect(model.selectionCount == 0)
        model.setSelection(names: ["\(decomposed).txt", "f1", "missing"])
        #expect(model.selectionCount == 2)
        model.setSelected(false, names: ["\(decomposed).txt"])
        #expect(model.selection == ["f1"])
    }
}

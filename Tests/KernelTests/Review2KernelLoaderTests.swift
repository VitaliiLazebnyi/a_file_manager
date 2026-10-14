@testable import AFMKernel
import Foundation
import TestSupport
import Testing

private func waitUntil(seconds: TimeInterval = 60, _ condition: () -> Bool) -> Bool {
    let end = Date(timeIntervalSinceNow: seconds)
    while !condition() {
        if Date() > end { return false }
        usleep(2000)
    }
    return true
}

/// A file system whose questions about one folder never come back until they are released:
/// a share whose server is gone.
private final class StalledFileSystem: FileSystemProvider {
    let inner = MemoryFileSystem(scheme: "stall")
    var scheme: String { inner.scheme }
    var capabilities: FileSystemCapabilities { [.write] }

    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var flags: [CancellationFlag] = []
    let release = DispatchSemaphore(value: 0)
    /// What blocks at the dead folder.
    var stallsVolume = true, stallsListing = false

    func count(_ what: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[what] ?? 0 }
    var handedFlags: [CancellationFlag] { lock.lock(); defer { lock.unlock() }; return flags }
    private func note(_ what: String, _ flag: CancellationFlag? = nil) {
        lock.lock()
        counts[what, default: 0] += 1
        if let flag { flags.append(flag) }
        lock.unlock()
    }

    private func isDead(_ url: URL) -> Bool { url.path.hasPrefix("/dead") }

    func volume(of url: URL) -> VolumeInfo? { VolumeInfo(name: "plain") }
    func volume(of url: URL, cancellation: CancellationFlag) -> VolumeInfo? {
        guard isDead(url), stallsVolume else { return VolumeInfo(name: "alive") }
        note("volume", cancellation)
        release.wait()
        return VolumeInfo(name: "back")
    }

    func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] { try inner.list(directory, showHidden: showHidden) }
    func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag, receive: ([FileItem]) -> Bool) throws {
        if isDead(directory), stallsListing {
            note("list", cancellation)
            release.wait()
        }
        _ = receive(try inner.list(directory, showHidden: showHidden))
    }
    func item(at url: URL) -> FileItem? { inner.item(at: url) }
    func parent(of directory: URL) -> URL? { inner.parent(of: directory) }
    func read(_ url: URL) throws -> FileReader { try inner.read(url) }
    func createDirectory(at url: URL) throws { try inner.createDirectory(at: url) }
    func write(_ url: URL) throws -> FileWriter { try inner.write(url) }
    func remove(_ url: URL) throws { try inner.remove(url) }
    func move(_ source: URL, to destination: URL, replacing: Bool) throws { try inner.move(source, to: destination, replacing: replacing) }
    func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws { try inner.copy(source, to: destination, progress: progress) }
}

/// Review 2, K004/K007/K039/K040: reading a panel's directory from a location that does not answer.
@Suite(.serialized) struct Review2KernelLoader {
    private func setUp() -> (StalledFileSystem, FileSystemRegistry) {
        let stalled = StalledFileSystem()
        _ = stalled.inner.addFile("/dead/a.txt")
        _ = stalled.inner.addFile("/alive/b.txt")
        _ = stalled.inner.addFile("/alive/c.txt")
        let registry = FileSystemRegistry()
        registry.register(stalled)
        return (stalled, registry)
    }

    /// One try at reading a location, on a thread of its own; `ended` is signalled when it returns.
    private func load(_ path: String, _ stalled: StalledFileSystem, _ registry: FileSystemRegistry, cancellation: CancellationFlag,
                      ended: DispatchSemaphore, names: @escaping ([String]) -> Void = { _ in }) {
        Thread.detachNewThread {
            var seen: [String] = []
            try? PanelLoader.stream(stalled.inner.url(path), showHidden: true, fileSystems: registry, cancellation: cancellation) { batch in
                seen += batch.listing.items.map(\.name)
                return true
            }
            names(seen)
            ended.signal()
        }
    }

    @Test func aVolumeThatDoesNotAnswerCostsOneThreadHoweverOftenItIsTried() {
        let (stalled, registry) = setUp()
        // A hundred refreshes of the dead folder, each given up.
        for _ in 0..<100 {
            let (cancellation, ended) = (CancellationFlag(), DispatchSemaphore(value: 0))
            load("/dead", stalled, registry, cancellation: cancellation, ended: ended)
            #expect(waitUntil { stalled.count("volume") >= 1 })
            cancellation.cancel()
            // The reader is free at once; it does not wait for the file system.
            #expect(ended.wait(timeout: .now() + 60) == .success)
        }
        #expect(stalled.count("volume") == 1)
        #expect(BlockingCalls.unanswered(for: stalled) == 1)
        // The question was told that nobody waits for it.
        #expect(stalled.handedFlags.first?.isCancelled == true)
        // A healthy folder of the same file system still loads.
        let (ended, got) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        var names: [String] = []
        load("/alive", stalled, registry, cancellation: CancellationFlag(), ended: ended) { names = $0; got.signal() }
        #expect(got.wait(timeout: .now() + 60) == .success)
        #expect(names.sorted() == ["b.txt", "c.txt"])
        // The share comes back: the stuck question ends, and the folder can be read.
        for _ in 0..<4 { stalled.release.signal() }
        #expect(waitUntil { BlockingCalls.unanswered(for: stalled) == 0 })
        stalled.stallsVolume = false
        let result = try? PanelLoader.load(stalled.inner.url("/dead"), showHidden: true, fileSystems: registry)
        #expect(result?.listing.items.map(\.name) == ["a.txt"] && result?.listing.volume?.name == "alive")
    }

    @Test func aListingThatDoesNotAnswerIsNotStartedASecondTime() {
        let (stalled, registry) = setUp()
        (stalled.stallsVolume, stalled.stallsListing) = (false, true)
        for round in 0..<40 {
            let (cancellation, ended) = (CancellationFlag(), DispatchSemaphore(value: 0))
            load("/dead", stalled, registry, cancellation: cancellation, ended: ended)
            if round == 0 { #expect(waitUntil { stalled.count("list") == 1 }) } else { usleep(1000) }
            cancellation.cancel()
            #expect(ended.wait(timeout: .now() + 60) == .success)
        }
        #expect(stalled.count("list") == 1 && BlockingCalls.unanswered(for: stalled) == 1)
        // Whoever still wants the folder waits, without a thread of the kernel's, until the
        // old listing has come back, and then reads it afresh.
        let (ended, got) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        var names: [String] = []
        load("/dead", stalled, registry, cancellation: CancellationFlag(), ended: ended) { names = $0; got.signal() }
        usleep(50_000)
        #expect(stalled.count("list") == 1)
        stalled.stallsListing = false
        stalled.release.signal()
        #expect(got.wait(timeout: .now() + 60) == .success)
        #expect(names == ["a.txt"])
        #expect(waitUntil { BlockingCalls.unanswered(for: stalled) == 0 })
    }

    @Test func batchesArriveOnTheThreadThatAskedAndErrorsAreThrownThere() throws {
        let memory = MemoryFileSystem(scheme: "mem")
        for index in 0..<50 { _ = memory.addFile("/big/file\(index).txt") }
        memory.listBatchSize = 7
        let registry = FileSystemRegistry()
        registry.register(memory)
        var own: UInt64 = 0
        pthread_threadid_np(nil, &own)
        var (batches, firsts, names, elsewhere) = (0, 0, [String](), 0)
        try PanelLoader.stream(memory.url("/big"), showHidden: true, fileSystems: registry) { batch in
            var id: UInt64 = 0
            pthread_threadid_np(nil, &id)
            if id != own { elsewhere += 1 }
            batches += 1
            if batch.isFirst { firsts += 1 }
            names += batch.listing.items.map(\.name)
            return true
        }
        #expect(batches > 1 && firsts == 1 && names.count == 50 && elsewhere == 0)
        // Wanting no more ends it.
        var taken = 0
        try PanelLoader.stream(memory.url("/big"), showHidden: true, fileSystems: registry) { _ in
            taken += 1
            return false
        }
        #expect(taken == 1)
        // A folder that is not there: the error is thrown here, and with climbing the folder above is read.
        #expect(throws: (any Error).self) { try PanelLoader.load(memory.url("/big/none"), showHidden: true, fileSystems: registry) }
        #expect(try PanelLoader.load(memory.url("/big/none"), showHidden: true, fileSystems: registry, climbing: true).listing.items.count == 50)
        // The location of a file leads to its folder.
        let atFile = try PanelLoader.load(memory.url("/big/file3.txt"), showHidden: true, fileSystems: registry)
        #expect(atFile.focus == "file3.txt" && atFile.listing.items.count == 50)
        #expect(BlockingCalls.unanswered(for: memory) == 0)
    }
}

/// A tree of folders one inside the other, as deep as wanted, with one file at every level.
private final class DeepFileSystem: FileSystemProvider {
    let scheme = "deep"
    let capabilities: FileSystemCapabilities = []
    let depth: Int
    /// A folder that shows itself as its own child, for ever.
    var isEndless = false
    private let lock = NSLock()
    private var listed = 0
    var listings: Int { lock.lock(); defer { lock.unlock() }; return listed }

    init(depth: Int) { self.depth = depth }

    func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        lock.lock(); listed += 1; lock.unlock()
        let level = directory.pathComponents.count - 1
        var items = [FileItem(url: directory.appendingPathComponent("f"), name: "f", isDirectory: false, size: 3)]
        if isEndless {
            items.append(FileItem(url: directory, name: "d", isDirectory: true))
        } else if level < depth {
            items.append(FileItem(url: directory.appendingPathComponent("d"), name: "d", isDirectory: true))
        }
        return items
    }
    func item(at url: URL) -> FileItem? { nil }
    func parent(of directory: URL) -> URL? { directory.pathComponents.count > 1 ? directory.deletingLastPathComponent() : nil }
    func read(_ url: URL) throws -> FileReader { throw FileSystemError.notSupported("Reading") }
    func createDirectory(at url: URL) throws {}
    func write(_ url: URL) throws -> FileWriter { throw FileSystemError.notSupported("Writing") }
    func remove(_ url: URL) throws {}
    func move(_ source: URL, to destination: URL, replacing: Bool) throws {}
    func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {}
}

/// Review 2, K003/K038: the size of a tree that is deeper than any stack.
@Suite struct Review2KernelTreeSize {
    /// On a thread with the small stack the pool's threads used to have.
    private func onSmallStack<Value>(_ work: @escaping () -> Value) -> Value? {
        let done = DispatchSemaphore(value: 0)
        var value: Value?
        let thread = Thread {
            value = work()
            done.signal()
        }
        thread.stackSize = 512 << 10
        thread.start()
        return done.wait(timeout: .now() + 300) == .success ? value : nil
    }

    @Test func aTreeDeeperThanAnyStackIsMeasuredToTheDepthNoRealTreeHas() {
        let top = URL(string: "deep:///")!
        // Shallow: every level counted, by calls that nest.
        let shallow = DeepFileSystem(depth: 20)
        #expect(onSmallStack { shallow.totalSize(of: top) } == Int64(3 * 21))
        // Deeper than the nesting allows, and still a real tree: every level counted.
        let deeper = DeepFileSystem(depth: 600)
        #expect(onSmallStack { deeper.totalSize(of: top) } == Int64(3 * 601))
        // Twenty thousand levels crashed the program; now the walk ends at its limit.
        let hostile = DeepFileSystem(depth: 20_000)
        let size = onSmallStack { hostile.totalSize(of: top) }
        #expect(size != nil && size! >= 3 * Int64(TreeWalk.deepestTree) && size! <= 3 * Int64(TreeWalk.deepestTree + TreeWalk.deepestNesting * 80))
        // A folder inside itself is listed once.
        let endless = DeepFileSystem(depth: 0)
        endless.isEndless = true
        #expect(onSmallStack { endless.totalSize(of: top) } != nil)
        #expect(endless.listings < 200)
    }

    @Test func cancellingEndsTheWalkWithNothing() {
        let top = URL(string: "deep:///")!
        let tree = DeepFileSystem(depth: 500)
        let cancellation = CancellationFlag()
        cancellation.cancel()
        #expect(tree.totalSize(of: top, cancellation: cancellation) == 0 && tree.listings == 0)
        #expect(TreeWalk.nesting == 0)
    }
}

/// Review 2, K037 and the path findings of the fuzzers: names and paths from outside.
@Suite struct Review2KernelPathSafety {
    @Test func aNameIsOneNameOrItIsRefused() {
        for name in ["a", "a.txt", "..a", "a..", "...", " ", "é", "a\u{301}", "\u{301}", "a\\b", "a b"] {
            #expect(PathSafety.isSafeName(name), "\(name.debugDescription)")
        }
        // The separator is a byte: one that carries an accent is still a separator.
        for name in ["", ".", "..", "a/b", "/", "/a", "a/", "a\u{0}b", "\u{0}", "/\u{301}", "a/\u{301}b", "../x", "..\u{2F}\u{301}"] {
            #expect(!PathSafety.isSafeName(name), "\(name.debugDescription)")
        }
        let root = URL(fileURLWithPath: "/tmp/review2-root")
        #expect(root.appending(safeName: "x.txt")?.path == "/tmp/review2-root/x.txt")
        #expect(root.appending(safeName: "../x") == nil && root.appending(safeName: "a/b") == nil && root.appending(safeName: "..") == nil)
    }

    @Test func aPathIsCutAtTheByteAndEveryPartChecked() {
        #expect(PathSafety.components(ofRelativePath: "a/b/c.txt") == ["a", "b", "c.txt"])
        #expect(PathSafety.components(ofRelativePath: "dir/", allowingTrailingSeparator: true) == ["dir"])
        #expect(PathSafety.components(ofRelativePath: "a/\u{301}b") == ["a", "\u{301}b"])
        // What the archive and split-file reproducers held: `..`, then a `/` with a combining
        // mark, which one character-based split took for part of a name.
        for path in ["../x", "a/../b", "..", ".", "a/./b", "/abs", "a//b", "a/", "", "a/\u{0}", "..\u{2F}\u{301}x", "..\u{2F}\u{301}/..\u{2F}\u{301}/x", "a/..\u{2F}\u{301}"] {
            #expect(PathSafety.components(ofRelativePath: path) == nil, "\(path.debugDescription)")
        }
        #expect(PathSafety.components(ofRelativePath: "a/b//", allowingTrailingSeparator: true) == nil)
        let root = URL(fileURLWithPath: "/tmp/review2-root")
        #expect(PathSafety.location(ofRelativePath: "a/b.txt", below: root)?.path == "/tmp/review2-root/a/b.txt")
        #expect(PathSafety.location(ofRelativePath: "..\u{2F}\u{301}x", below: root) == nil)
        #expect(PathSafety.location(ofRelativePath: "../review2-root-other/x", below: root) == nil)
    }

    @Test func aLocationIsBelowItsRootByBytesNotByLooks() throws {
        let root = URL(fileURLWithPath: "/tmp/review2-root")
        #expect(PathSafety.isContained(URL(fileURLWithPath: "/tmp/review2-root/a/b"), in: root))
        #expect(PathSafety.isContained(URL(fileURLWithPath: "/tmp/review2-root/a/../b"), in: root))
        #expect(!PathSafety.isContained(root, in: root))
        #expect(!PathSafety.isContained(URL(fileURLWithPath: "/tmp/review2-root/../x"), in: root))
        #expect(!PathSafety.isContained(URL(fileURLWithPath: "/tmp/review2-rootx/a"), in: root))
        #expect(!PathSafety.isContained(URL(fileURLWithPath: "/tmp/review2-root\u{301}/a"), in: root))
        #expect(!PathSafety.isContained(URL(string: "ftp://host/tmp/review2-root/a")!, in: root))
        #expect(PathSafety.isContained(URL(string: "ftp://host/pub/a")!, in: URL(string: "ftp://host/pub")!))
        #expect(!PathSafety.isContained(URL(string: "ftp://other/pub/a")!, in: URL(string: "ftp://host/pub")!))
        // Two folders whose names read the same are two folders, where the file system keeps
        // both (a server; the Mac's own disks write every name one way).
        let composed = URL(string: "ftp://host/caf%C3%A9")!, decomposed = URL(string: "ftp://host/cafe%CC%81/x")!
        #expect(composed.path == decomposed.deletingLastPathComponent().path)
        #expect(!PathSafety.isContained(decomposed, in: composed) && !decomposed.isInside(composed))
        #expect(URL(string: "ftp://host/caf%C3%A9/x")!.isInside(composed) && PathSafety.isContained(URL(string: "ftp://host/caf%C3%A9/x")!, in: composed))
        #expect(!URL(fileURLWithPath: "/tmp/review2-root\u{301}/a").isInside(root))
        // A link inside the folder that points out of it.
        let sandbox = try Sandbox()
        let inside = sandbox.root.appendingPathComponent("inside"), outside = sandbox.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: inside.appendingPathComponent("link"), withDestinationURL: outside)
        let through = inside.appendingPathComponent("link/file.txt")
        #expect(PathSafety.isContained(through, in: inside))
        #expect(!PathSafety.isContained(through, in: inside, resolvingLinks: true))
        #expect(PathSafety.isContained(inside.appendingPathComponent("plain.txt"), in: inside, resolvingLinks: true))
    }
}

/// Review 2, K049 and K031: file masks.
@Suite struct Review2KernelFileMask {
    @Test func masksMatchNamesHoweverTheirAccentsAreWritten() {
        let (composed, decomposed) = ("caf\u{E9}.txt", "cafe\u{301}.txt")
        for mask in ["caf\u{E9}*", "cafe\u{301}*", "*\u{E9}.txt", "CAF\u{C9}.TXT", "caf?.txt", "*f?.*"] {
            #expect(FileMask(mask).matches(composed) && FileMask(mask).matches(decomposed), "\(mask.debugDescription)")
        }
        #expect(!FileMask("caf??.txt").matches(composed) && !FileMask("caf??.txt").matches(decomposed))
    }

    @Test func aQuestionMarkIsOneCharacterOfAnySize() {
        #expect(FileMask("?.txt").matches("😀.txt") && FileMask("?.txt").matches("写.txt") && FileMask("?.txt").matches("a.txt"))
        #expect(!FileMask("?.txt").matches("ab.txt") && !FileMask("??.txt").matches("😀.txt"))
        #expect(FileMask("写?.jpg").matches("写真.jpg") && FileMask("*?真.JPG").matches("写真.jpg"))
    }

    @Test func bracketsAndBackslashesStandForThemselves() {
        #expect(FileMask("report[1].txt").matches("report[1].txt") && !FileMask("report[1].txt").matches("report1.txt"))
        #expect(FileMask("[a-c]*").matches("[a-c] notes.md") && !FileMask("[a-c]*").matches("b.md"))
        #expect(FileMask("a\\b*").matches("a\\b.txt") && FileMask("*[*").matches("x[y") && FileMask("\\*").matches("\\anything"))
    }

    @Test func caseDoesNotCountInAnyScript() {
        #expect(FileMask("STRASSE*").matches("straße.txt") && FileMask("straße*").matches("STRASSE.TXT"))
        #expect(FileMask("*ФАЙЛ*").matches("мой файл.txt") && FileMask("*.TXT").matches("отчёт.txt") && FileMask("É*").matches("été"))
        #expect(FileMask("*.").matches("noext") && !FileMask("*.").matches("has.ext") && FileMask("name.").matches("NAME"))
    }

    @Test func noMaskTakesLongOnAnyName() {
        // The shapes that make a matcher go back and forth: many `*` against a name that
        // nearly fits. Bounded by the two lengths multiplied, whatever they hold.
        let name = String(repeating: "a", count: 4000)
        let masks = [String(repeating: "*a", count: 60) + "*b", String(repeating: "a*", count: 100) + "?b", "*" + String(repeating: "?", count: 300) + "b",
                     String(repeating: "*", count: 500) + "b"]
        for mask in masks {
            #expect(!FileMask(mask).matches(name))
            #expect(!FileMask(mask).matches(name + "é"))
            #expect(FileMask(mask).matches(name + "b"))
        }
    }
}

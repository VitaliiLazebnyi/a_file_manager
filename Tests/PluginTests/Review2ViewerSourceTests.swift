import AFMKernel
import Darwin
import Foundation
import ImageIO
import LocalFileSystemPlugin
import TestSupport
import Testing
import UniformTypeIdentifiers
@testable import ViewerPlugin

/// A file system of a few made-up files, for what the memory file system cannot do: readers that
/// are slow to close, and files that do not end.
final class Review2HookProvider: FileSystemProvider {
    let scheme = "hook"
    let capabilities: FileSystemCapabilities = []
    var sizes: [String: Int64] = [:]
    var special: Set<String> = []
    var contents: [String: Data] = [:]
    var endless: Set<String> = []
    private let lock = NSLock()
    private var closed = 0
    /// Called by `close()` of every reader.
    var onClose: () -> Void = {}
    var closeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] { [] }
    func parent(of directory: URL) -> URL? { directory.deletingLastPathComponent() }
    func createDirectory(at url: URL) throws { throw FileSystemError.notSupported("x") }
    func write(_ url: URL) throws -> FileWriter { throw FileSystemError.notSupported("x") }
    func remove(_ url: URL) throws {}
    func move(_ source: URL, to destination: URL, replacing: Bool) throws {}
    func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {}

    func item(at url: URL) -> FileItem? {
        FileItem(url: url, name: url.lastPathComponent, isDirectory: false, size: sizes[url.path] ?? Int64(contents[url.path]?.count ?? 0),
                 isSpecial: special.contains(url.path))
    }

    private final class Reader: FileReader {
        let owner: Review2HookProvider
        let data: Data?
        var position = 0
        init(_ owner: Review2HookProvider, data: Data?) {
            self.owner = owner
            self.data = data
        }

        func read(upToCount count: Int) throws -> Data? {
            guard let data else { return Data(repeating: 0x41, count: count) }
            guard position < data.count else { return nil }
            let block = data.subdata(in: position..<min(data.count, position + count))
            position += block.count
            return block
        }

        func seek(to offset: UInt64) throws { position = Int(offset) }

        func close() {
            owner.onClose()
            owner.lock.lock()
            owner.closed += 1
            owner.lock.unlock()
        }
    }

    func read(_ url: URL) throws -> FileReader {
        Reader(self, data: endless.contains(url.path) ? nil : contents[url.path] ?? Data(count: Int(sizes[url.path] ?? 0)))
    }
}

/// Review round 2, the sources of bytes: opening links and special files, closing readers off the
/// calling thread, saving, the copies for the players, and the rules for links in a viewed file.
@Suite struct Review2ViewerSource {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("afm-r2viewer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func local() -> FileSystemRegistry {
        let registry = FileSystemRegistry()
        registry.register(LocalFileSystem())
        return registry
    }

    // MARK: Opening

    @Test func aLinkToAFileIsOpenedWithTheSizeOfItsTarget() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.log")
        try Data(repeating: UInt8(ascii: "x"), count: 5000).write(to: target)
        let link = directory.appendingPathComponent("current.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let source = try ProviderByteSource.open(link, fileSystems: local())
        #expect(source is ProviderByteSource && source.length == 5000)
        #expect(try source.read(at: 4990, count: 100).count == 10)
        // An empty file is empty, through a link too.
        let empty = directory.appendingPathComponent("empty")
        try Data().write(to: empty)
        let emptyLink = directory.appendingPathComponent("empty-link")
        try FileManager.default.createSymbolicLink(at: emptyLink, withDestinationURL: empty)
        #expect(try ProviderByteSource.open(emptyLink, fileSystems: local()).length == 0)
        #expect(try ProviderByteSource.open(empty, fileSystems: local()).length == 0)
    }

    @Test func devicesAndPipesAreRefusedWithoutBeingRead() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        for path in ["/dev/zero", "/dev/null"] {
            #expect(throws: ViewerError.self) { try ProviderByteSource.open(URL(fileURLWithPath: path), fileSystems: local()) }
        }
        let zero = directory.appendingPathComponent("zero-link")
        try FileManager.default.createSymbolicLink(at: zero, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        #expect(throws: ViewerError.self) { try ProviderByteSource.open(zero, fileSystems: local()) }
        // A FIFO would block on open() forever.
        let fifo = directory.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let outcome = ViewerAdoptBox<Bool>(false)
        let worker = ViewerAdoptWorker { outcome.value = (try? ProviderByteSource.open(fifo, fileSystems: local())) == nil }
        worker.start()
        #expect(worker.waitUntilFinished(timeout: 20) && outcome.value)
    }

    @Test func measuringAFileOfUnknownSizeStopsWithItsFlag() throws {
        let provider = Review2HookProvider()
        provider.endless = ["/stream"]
        let registry = FileSystemRegistry()
        registry.register(provider)
        let flag = CancellationFlag()
        let outcome = ViewerAdoptBox<Result<ByteSource, Error>?>(nil)
        let worker = ViewerAdoptWorker {
            outcome.value = Result { try ProviderByteSource.open(URL(string: "hook:///stream")!, fileSystems: registry, cancellation: flag) }
        }
        worker.start()
        usleep(30_000)
        flag.cancel()
        #expect(worker.waitUntilFinished(timeout: 20))
        if case .success? = outcome.value { Issue.record("The stream was opened") }
    }

    @Test func specialEntriesAreRefusedWhateverTheFileSystem() throws {
        let provider = Review2HookProvider()
        provider.endless = ["/stream"]
        provider.special = ["/stream"]
        let registry = FileSystemRegistry()
        registry.register(provider)
        #expect(throws: ViewerError.self) { try ProviderByteSource.open(URL(string: "hook:///stream")!, fileSystems: registry) }
    }

    // MARK: Closing

    @Test func closingTheSourceDoesNotWaitForTheReaders() throws {
        let provider = Review2HookProvider()
        provider.contents["/a"] = Data(repeating: 0x42, count: 100_000)
        let registry = FileSystemRegistry()
        registry.register(provider)
        let gate = DispatchSemaphore(value: 0)
        provider.onClose = { _ = gate.wait(timeout: .now() + 20) }
        let source = try ProviderByteSource.open(URL(string: "hook:///a")!, fileSystems: registry)
        _ = try source.read(at: 0, count: 10)
        // The close of the reader blocks (a server that does not answer): `close` returns anyway.
        let started = Date()
        source.close()
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(provider.closeCount == 0)
        gate.signal()
        ViewerCleanup.drain()
        #expect(provider.closeCount == 1)
    }

    @Test func aReaderInUseWhenTheSourceIsClosedIsClosedWhenItComesBack() throws {
        let provider = Review2HookProvider()
        provider.contents["/a"] = Data(repeating: 0x42, count: 100_000)
        let registry = FileSystemRegistry()
        registry.register(provider)
        let source = try ProviderByteSource.open(URL(string: "hook:///a")!, fileSystems: registry)
        // Two readers: one idle, one that was out when `close` came.
        _ = try source.read(at: 0, count: 10)
        source.close()
        ViewerCleanup.drain()
        #expect(provider.closeCount == 1)
        _ = try source.read(at: 0, count: 10)
        source.close()
        ViewerCleanup.drain()
        #expect(provider.closeCount == 2)
        // Letting go of the source closes what it holds, off the thread that lets go.
        var again: ProviderByteSource? = try #require(try ProviderByteSource.open(URL(string: "hook:///a")!, fileSystems: registry) as? ProviderByteSource)
        _ = try again?.read(at: 0, count: 10)
        again = nil
        ViewerCleanup.drain()
        #expect(provider.closeCount == 3)
    }

    // MARK: The block cache

    @Test func aShortBlockIsNotKeptInMemory() throws {
        final class Flaky: ByteSource {
            let length: Int64 = 40_000
            var short = true
            func read(at offset: Int64, count: Int) throws -> Data {
                let wanted = min(count, 40_000 - Int(offset))
                return Data(repeating: 0x61, count: short ? wanted / 2 : wanted)
            }
        }
        let base = Flaky()
        let cached = CachedByteSource(base, blockSize: 4096, capacity: 8)
        // A read that came back short ...
        #expect(try cached.read(at: 0, count: 100).count == 100)
        base.short = false
        // ... is not remembered: the next one asks again and gets the whole block.
        #expect(try cached.read(at: 0, count: 4096).count == 4096)
        #expect(try cached.read(at: 0, count: 4096).count == 4096)
    }

    @Test func aLongReadOfFourBlocksGoesPastTheMemoryCache() throws {
        let data = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0) })
        let cached = CachedByteSource(DataByteSource(data), blockSize: 256 << 10, capacity: 4)
        _ = try cached.read(at: 0, count: 1 << 20)
        // Four blocks of 256 KB are a scan: nothing was kept, a read of one block still works.
        #expect(try cached.read(at: 300_000, count: 100) == data.subdata(in: 300_000..<300_100))
    }

    // MARK: Save as

    @Test func savingOntoTheViewedFileIsRecognisedAndRefused() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.txt")
        try Data("content".utf8).write(to: file)
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let hard = directory.appendingPathComponent("hard.txt")
        try FileManager.default.linkItem(at: file, to: hard)
        #expect(ViewerSave.isSameFile(file, file) && ViewerSave.isSameFile(file, link) && ViewerSave.isSameFile(link, file) && ViewerSave.isSameFile(file, hard))
        #expect(!ViewerSave.isSameFile(file, directory.appendingPathComponent("other.txt")) && !ViewerSave.isSameFile(nil, file))
        // A target that does not exist yet, spelled differently.
        #expect(ViewerSave.isSameFile(directory.appendingPathComponent("x/../a.txt"), file))
    }

    @Test func aSaveWritesATemporaryFileAndMovesItIntoPlace() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("copy.bin")
        try Data("old".utf8).write(to: target)
        let data = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        var last: Int64 = 0
        try ViewerSave.save(DataByteSource(data), to: target, cancellation: CancellationFlag()) { last = $0 }
        #expect(try Data(contentsOf: target) == data && last == Int64(data.count))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["copy.bin"])
    }

    @Test func aSaveOfAFileThatBecameShorterFailsAndLeavesTheTargetAlone() throws {
        final class Short: ByteSource {
            let length: Int64 = 2_000_000
            func read(at offset: Int64, count: Int) throws -> Data {
                offset >= 1_500_000 ? Data() : Data(repeating: 0x42, count: min(count, 1_500_000 - Int(offset)))
            }
        }
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("copy.bin")
        try Data("old".utf8).write(to: target)
        #expect(throws: ViewerError.fileChanged) { try ViewerSave.save(Short(), to: target, cancellation: CancellationFlag()) }
        #expect(try Data(contentsOf: target) == Data("old".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["copy.bin"])
        // Cancelled: the same.
        let flag = CancellationFlag()
        flag.cancel()
        #expect(throws: (any Error).self) { try ViewerSave.save(DataByteSource(Data(count: 100)), to: target, cancellation: flag) }
        #expect(try Data(contentsOf: target) == Data("old".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["copy.bin"])
    }

    // MARK: Temporary copies

    @Test func theNameOfACopyIsOneSafeComponent() {
        for name in ["..", ".", "", "../../x", "a/b", "a\\b", "x:y", "..%2F..%2Fx", "\u{0}evil", String(repeating: "n", count: 400) + ".mov"] {
            let safe = TemporaryCopies.safeName(name)
            #expect(!safe.isEmpty && safe != "." && safe != ".." && !safe.contains("/") && !safe.contains(":") && !safe.contains("\u{0}"), "\(name.debugDescription) -> \(safe.debugDescription)")
            #expect(safe.utf8.count <= 255)
        }
        #expect(TemporaryCopies.safeName("../../x") == "_.._.._x")
        #expect(TemporaryCopies.safeName("movie.mp4") == "movie.mp4")
        #expect(TemporaryCopies.safeName(String(repeating: "n", count: 400) + ".mov").hasSuffix(".mov"))
    }

    @Test func aNameWithEncodedSeparatorsStaysInsideItsFolder() throws {
        let provider = Review2HookProvider()
        // As a server sends it: the last component is "../../escape.mp4" once decoded.
        let url = URL(string: "hook:///a/..%2F..%2Fescape.mp4")!
        #expect(url.lastPathComponent == "../../escape.mp4")
        provider.contents[url.path] = Data("payload".utf8)
        let registry = FileSystemRegistry()
        registry.register(provider)
        let copies = TemporaryCopies()
        defer { copies.removeAll() }
        let copy = try #require(copies.localURL(for: url, fileSystems: registry, cancellation: CancellationFlag()))
        let folder = copy.deletingLastPathComponent().standardizedFileURL
        #expect(copy.standardizedFileURL.deletingLastPathComponent() == folder && !copy.lastPathComponent.contains("/"))
        #expect(try String(contentsOf: copy, encoding: .utf8) == "payload")
        let root = folder.deletingLastPathComponent().deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.mp4").path))
    }

    @Test func aFileTooBigToCopyIsRefusedBeforeAByteIsRead() {
        let registry = FileSystemRegistry()
        let provider = Review2HookProvider()
        provider.sizes["/huge.mov"] = 50 << 30
        registry.register(provider)
        let copies = TemporaryCopies()
        defer { copies.removeAll() }
        let result = copies.localCopy(for: URL(string: "hook:///huge.mov")!, fileSystems: registry, cancellation: CancellationFlag())
        if case .failure(let refusal) = result { #expect(refusal == .tooLarge(50 << 30) && refusal.message.contains("too large")) } else { Issue.record("copied") }
        #expect(provider.closeCount == 0)
    }

    @Test func aCopyIsNotRegisteredForAPaneThatLetGoMeanwhileOrAfterRemoveAll() throws {
        let memory = MemoryFileSystem()
        let registry = FileSystemRegistry()
        registry.register(memory)
        let url = memory.addFile("/a/clip.mp4", String(repeating: "c", count: 1000))
        let copies = TemporaryCopies()
        defer { copies.removeAll() }
        let owner = ObjectIdentifier(copies)
        let first = try #require(copies.localURL(for: url, fileSystems: registry, owner: owner, cancellation: CancellationFlag()))
        copies.removeAll()
        copies.waitForCleanup()
        // The folder is gone with its entry: copying again makes a new one.
        #expect(!FileManager.default.fileExists(atPath: first.path))
        let second = try #require(copies.localURL(for: url, fileSystems: registry, owner: owner, cancellation: CancellationFlag()))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    // MARK: Links

    @Test func onlyWebAndMailLinksOpenInTheBrowser() {
        #expect(LinkPolicy.opensInBrowser(URL(string: "https://example.com/a")!) && LinkPolicy.opensInBrowser(URL(string: "http://example.com")!))
        #expect(LinkPolicy.opensInBrowser(URL(string: "mailto:a@example.com")!))
        for text in ["file:///Applications/Calculator.app", "smb://evil/share", "sftp://evil/x", "ftp://evil/x", "x-evil-scheme://run", "javascript:alert(1)", "tel:123", "relative.html"] {
            #expect(!LinkPolicy.opensInBrowser(URL(string: text)!), "\(text)")
        }
    }

    @Test func aPageCanOnlyLeadToFilesBesideTheOneShown() {
        let base = URL(fileURLWithPath: "/Users/me/pages/index.html")
        func target(_ text: String) -> String? { LinkPolicy.target(of: URL(string: text)!, relativeTo: base)?.path }
        #expect(target("other.html") == "/Users/me/pages/other.html")
        #expect(target("sub/page.html#part") == "/Users/me/pages/sub/page.html")
        for text in ["../secret.html", "../../etc/passwd", "file:///etc/passwd", "file:///Users/me/other/x.html", "sftp://evil/x", "ftp://evil/x", "smb://evil/x",
                     "http://evil/x", "..%2F..%2Fx", "sub/..%2F..%2Fx", "/etc/passwd", "//evil/x"] {
            #expect(target(text) == nil, "\(text) -> \(target(text) ?? "nil")")
        }
        // The same file system and host only.
        let remote = URL(string: "sftp://host/pub/doc/index.html")!
        func remoteTarget(_ text: String) -> String? { LinkPolicy.target(of: URL(string: text)!, relativeTo: remote)?.absoluteString }
        #expect(remoteTarget("next.html") == "sftp://host/pub/doc/next.html")
        #expect(remoteTarget("sftp://other/pub/doc/next.html") == nil && remoteTarget("ftp://host/pub/doc/next.html") == nil && remoteTarget("../up.html") == nil)
    }

    @Test func aPageShownFromAStringNavigatesOnceAndThenNowhere() {
        let blank = URL(string: "about:blank")
        typealias Page = WebContentView
        // The load of the page itself, once.
        #expect(Page.decide(isMainFrame: true, isLinkClick: false, url: blank, expectsPage: true) == .allow)
        // A meta refresh, a redirect, a script-less load of the web or of a file, a frame: refused.
        for text in ["https://evil.example/x", "http://127.0.0.1:18473/refresh", "file:///etc/passwd", "ftp://evil/x"] {
            #expect(Page.decide(isMainFrame: true, isLinkClick: false, url: URL(string: text), expectsPage: false) == .cancel, "\(text)")
            #expect(Page.decide(isMainFrame: true, isLinkClick: false, url: URL(string: text), expectsPage: true) == .cancel, "\(text)")
        }
        #expect(Page.decide(isMainFrame: true, isLinkClick: false, url: nil, expectsPage: true) == .allow)
        #expect(Page.decide(isMainFrame: true, isLinkClick: false, url: blank, expectsPage: false) == .cancel)
        #expect(Page.decide(isMainFrame: false, isLinkClick: false, url: blank, expectsPage: true) == .cancel)
        // A click is handed on, and a jump inside the page stays.
        #expect(Page.decide(isMainFrame: true, isLinkClick: true, url: URL(string: "https://example.com"), expectsPage: false) == .followLink)
        #expect(Page.decide(isMainFrame: true, isLinkClick: true, url: URL(string: "about:blank#part"), expectsPage: false) == .allow)
    }

    // MARK: Encodings

    @Test func codePagesThatCannotBeDecodedAreNotOffered() {
        // EUC-JP and GB 18030 were taken out in the first pass and are back (second pass), decoded by their layout; other
        // code pages of many bytes (ISO-2022, EUC-KR, HZ ...) are still not offered.
        #expect(ViewerEncoding.codePage(51932) != nil && ViewerEncoding.codePage(54936) != nil)
        for page in [50220, 50221, 50222, 51949, 52936] { #expect(ViewerEncoding.codePage(page) == nil, "\(page)") }
        for page in [1252, 437, 866, 932, 936, 949, 950, 28591, 20866, 65001] { #expect(ViewerEncoding.codePage(page) != nil, "\(page)") }
        #expect(ViewerEncoding.codePages.contains(.ansi) && ViewerEncoding.codePages.contains { $0.codePage == 932 })
    }

    // MARK: Folders

    @Test func countingAFolderOnAServerStopsAtItsLimit() {
        let memory = MemoryFileSystem()
        for folder in 0..<5 {
            for file in 0..<20 { memory.addFile("/tree/d\(folder)/f\(file).txt", String(repeating: "a", count: 10)) }
        }
        let all = FolderSummary.measure(memory.url("/tree"), provider: memory, cancellation: CancellationFlag())
        #expect(all.files == 100 && all.folders == 5 && !all.isPartial)
        let limited = FolderSummary.measure(memory.url("/tree"), provider: memory, cancellation: CancellationFlag(), limit: 30)
        #expect(limited.isPartial && limited.files < 100 && limited.text.hasPrefix("At least "))
    }
}

import AFMContracts
import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FolderTabsPlugin
@testable import NavigationPlugin
@testable import PlacesPlugin
@testable import VirtualFoldersPlugin

/// Waits until the main queue has run what was put on it before.
private func drainMainQueue() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { continuation.resume() }
    }
}

/// A folder tree on a made-up scheme, with watchers that can be fired from any thread.
/// Unchecked: what it records is guarded by `lock`; its switches are set by the test before use.
private final class Review2WatchFileSystem: FileSystemProvider, @unchecked Sendable {
    let scheme: String
    init(scheme: String = "r2watch") { self.scheme = scheme }
    let capabilities: FileSystemCapabilities = []
    private let lock = NSLock()
    private var watches: [([URL], @Sendable ([URL]) -> Void)] = []
    var watchedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return watches.reduce(0) { $0 + $1.0.count }
    }

    func url(_ path: String) -> URL { URL(string: scheme + "://" + path)! }
    func fire() {
        lock.lock()
        let all = watches
        lock.unlock()
        for (directories, report) in all { report(directories) }
    }

    func list(_: URL, showHidden _: Bool) -> [FileItem] { [] }
    func item(at url: URL) -> FileItem? { FileItem(url: url, name: url.lastPathComponent, isDirectory: false) }
    func parent(of directory: URL) -> URL? { directory.path == "/" ? nil : directory.deletingLastPathComponent() }
    func read(_: URL) throws -> any FileReader { throw FileSystemError.notSupported("Reading") }
    func createDirectory(at _: URL) throws { throw FileSystemError.notSupported("Writing") }
    func write(_: URL) throws -> any FileWriter { throw FileSystemError.notSupported("Writing") }
    func remove(_: URL) throws { throw FileSystemError.notSupported("Writing") }
    func move(_: URL, to _: URL, replacing _: Bool) throws {
        throw FileSystemError.notSupported("Writing")
    }
    func copy(_: URL, to _: URL, progress _: (Int64) -> Bool) throws {
        throw FileSystemError.notSupported("Writing")
    }

    func watch(_ directories: [URL], onChange: @escaping @MainActor @Sendable ([URL]) -> Void) -> (any WatchToken)? {
        lock.lock()
        // Fired from any thread on purpose, against the rule that reports come on the main
        // thread: the tests show that whoever watches through a virtual folder still hears on it.
        watches.append((directories, unsafeBitCast(onChange, to: (@Sendable ([URL]) -> Void).self)))
        lock.unlock()
        return self
    }
}

@Suite struct Review2ConfigBVirtualFileSystem {
    @Test func theRegistryGoesWithTheFileSystemsInIt() {
        weak var gone: FileSystemRegistry?
        do {
            let registry = FileSystemRegistry()
            registry.register(VirtualFileSystem(fileSystems: registry))
            gone = registry
        }
        #expect(gone == nil)
    }

    @Test func watcherReportsReachTheCallerOnTheMainThreadWhicheverThreadFiresThem() async {
        let provider = Review2WatchFileSystem()
        let registry = FileSystemRegistry()
        registry.register(provider)
        let virtual = VirtualFileSystem(fileSystems: registry)
        let list = virtual.register(files: [provider.url("/top/sub/f.txt")], title: "L", origin: nil)
        let threads = Mutex<[Bool]>([])
        let watcher = virtual.watch([list]) { _ in threads.mutate { $0.append(Thread.isMainThread) } }
        #expect(watcher != nil)
        // From a background thread, as a file system's own queue would.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                provider.fire()
                continuation.resume()
            }
        }
        await drainMainQueue()
        #expect(threads.value == [true])
        withExtendedLifetime(watcher) {}
    }

    @Test func aReportAfterTheWatcherWasReleasedGoesNowhere() async throws {
        let provider = Review2WatchFileSystem()
        let registry = FileSystemRegistry()
        registry.register(provider)
        let virtual = VirtualFileSystem(fileSystems: registry)
        let list = virtual.register(files: [provider.url("/top/f.txt")], title: "L", origin: nil)
        let count = Mutex<Int>(0)
        var watcher = virtual.watch([list]) { _ in count.mutate { $0 += 1 } }
        provider.fire()
        await drainMainQueue()
        #expect(count.value == 1)
        // A second report within the window is held back; releasing the watcher drops it.
        provider.fire()
        watcher = nil
        try await Task.sleep(nanoseconds: 1_300_000_000)
        await drainMainQueue()
        #expect(count.value == 1)
        _ = watcher
    }

    @Test func aHugeListIsRegisteredWithoutWorkOnTheCallerAndWatchedByAtMostTheLimit() {
        let provider = Review2WatchFileSystem()
        let registry = FileSystemRegistry()
        registry.register(provider)
        let virtual = VirtualFileSystem(fileSystems: registry)
        // 20,000 files in as many folders; twice named files are one.
        let files = (0..<20_000).map { provider.url("/d\($0)/f.txt") } + [provider.url("/d1/f.txt")]
        let list = virtual.register(files: files, title: "Many", origin: nil)
        let watcher = virtual.watch([list]) { _ in }
        #expect(watcher != nil)
        #expect(provider.watchedCount <= VirtualFileSystem.watchLimit)
        // Waits for the background preparation: every file once.
        #expect(virtual.entries(of: list)?.count == 20_000)
        #expect(virtual.volume(of: list)?.isLocal == false)
    }

    @Test func filesThatDifferOnlyInUnicodeNormalisationAreTwoFilesInAList() throws {
        let provider = Review2WatchFileSystem()
        let registry = FileSystemRegistry()
        registry.register(provider)
        let virtual = VirtualFileSystem(fileSystems: registry)
        let composed = provider.url("/d/caf\u{E9}.txt")
        let decomposed = provider.url("/d/cafe\u{301}.txt")
        let list = virtual.register(files: [composed, decomposed, composed], title: "T", origin: nil)
        let entries = try #require(virtual.entries(of: list))
        #expect(entries.count == 2)
        let items = try virtual.list(list, showHidden: false)
        #expect(items.count == 2 && Set(items.map { Array($0.name.utf8) }).count == 2)
    }

    @Test func namesInASelectedBranchNeverClash() {
        let items = [
            FileItem(url: URL(fileURLWithPath: "/a/x.txt"), name: "x.txt", isDirectory: false),
            FileItem(url: URL(fileURLWithPath: "/b/x.txt"), name: "x.txt", isDirectory: false),
            FileItem(url: URL(fileURLWithPath: "/c/y"), name: "y", isDirectory: false),
            FileItem(url: URL(fileURLWithPath: "/d/y"), name: "y", isDirectory: false)
        ]
        // Two paths that read alike are told apart as well.
        let names = VirtualFileSystem.uniqueNames(of: items) { _ in "same" }
        #expect(names == ["same", "same (2)", "same (3)", "same (4)"])
        let plain = VirtualFileSystem.uniqueNames(of: items) { $0.url.path }
        #expect(plain == ["/a/x.txt", "/b/x.txt", "/c/y", "/d/y"])
    }

    @Test func leastRecentlyUsedUnwatchedListGoesFirst() {
        let provider = Review2WatchFileSystem()
        let registry = FileSystemRegistry()
        registry.register(provider)
        let virtual = VirtualFileSystem(fileSystems: registry)
        let first = virtual.register(files: [provider.url("/a/1")], title: "first", origin: nil)
        let second = virtual.register(files: [provider.url("/a/2")], title: "second", origin: nil)
        for index in 0..<(VirtualFileSystem.listLimit - 2) {
            _ = virtual.register(files: [provider.url("/x/\(index)")], title: "f\(index)", origin: nil)
        }
        // Using the first list makes the second the one that has been left alone longest.
        _ = virtual.entries(of: first)
        _ = virtual.register(files: [provider.url("/a/new")], title: "new", origin: nil)
        #expect(virtual.entries(of: first) != nil && virtual.entries(of: second) == nil)
    }

    @Test func capabilitiesWithoutALocationClaimNothingAnyShownFolderCannotDo() throws {
        let box = try Sandbox()
        try box.file("a/one.txt")
        let registry = FileSystemRegistry()
        registry.register(LocalFileSystem())
        let limited = Review2WatchFileSystem()
        registry.register(limited)
        let virtual = VirtualFileSystem(fileSystems: registry)
        _ = try virtual.list(virtual.branch(of: box.url("a")), showHidden: false)
        let local = virtual.capabilities
        let list = virtual.register(files: [limited.url("/a/1")], title: "L", origin: nil)
        _ = try virtual.list(list, showHidden: false)
        #expect(virtual.capabilities.isSubset(of: local) && virtual.capabilities.isSubset(of: limited.capabilities))
    }

    @Test func realLocationOfABranchItemIsTheRealFile() {
        let registry = FileSystemRegistry()
        let virtual = VirtualFileSystem(fileSystems: registry)
        let real = URL(fileURLWithPath: "/Users/x/dir/a.txt")
        #expect(virtual.realLocation(of: VirtualLocation.branch(of: real).url) == real)
        #expect(virtual.realLocation(of: real) == nil)
        #expect(virtual.realLocation(of: VirtualLocation.list(id: 1, title: "T", origin: nil).url) == nil)
    }

    @Test func aTypedListNoteNeedsTheListsOwnTitle() {
        let provider = Review2WatchFileSystem()
        let registry = FileSystemRegistry()
        registry.register(provider)
        let virtual = VirtualFileSystem(fileSystems: registry)
        let list = virtual.register(files: [provider.url("/a/1")], title: "Found", origin: nil)
        let shown = virtual.displayPath(list)
        #expect(virtual.location(from: shown) == list)
        #expect(virtual.location(from: shown.replacingOccurrences(of: "Found", with: "Photos")) == nil)
    }
}

@Suite struct Review2ConfigBVirtualLocation {
    @Test func aPasswordIsNeverWrittenIntoALocation() throws {
        let server = try #require(URL(string: "ftp://someone:s3cret@files.example.org/pub"))
        let url = VirtualLocation.branch(of: server).url
        #expect(!url.absoluteString.contains("s3cret"))
        let hostText = try #require(url.host)
        let hex = hostText.split(separator: ".").dropFirst().filter { $0.hasPrefix("h") }.map { $0.dropFirst() }
            .joined()
        let decoded = String(
            bytes: stride(from: 0, to: hex.count, by: 2).compactMap { index -> UInt8? in
                let start = hex.index(hex.startIndex, offsetBy: index)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)
            }, encoding: .utf8)
        #expect(decoded?.contains("s3cret") == false)
        #expect(VirtualLocation(url)?.realDirectory?.user == "someone")
    }

    @Test func aPathWithDotsInItIsMadePlain() throws {
        let hand = try #require(URL(string: "vfolder://branch.h66696c653a2f2f/a/../../etc"))
        guard case .branch(let real)? = VirtualLocation(hand) else {
            Issue.record("not a branch")
            return
        }
        #expect(real.path == "/etc")
        #expect(VirtualLocation.plain("/a/./b//c/..") == "/a/b")
    }
}

@Suite struct Review2ConfigBListFiles {
    @Test func namesWithLineBreaksSurviveAListFile() {
        let names = [
            "/tmp/plain.txt", "/tmp/with\nbreak.txt", "/tmp/with\r\nboth", "/tmp/tab\there", " /tmp/leading",
            "/tmp/trailing ", "\"/quoted\"",
            "/tmp/back\\slash", "/tmp/ctrl\u{7}bell", "/tmp/sep\u{2028}line"
        ]
        let text = FileListFile.text(for: names)
        #expect(!text.contains("with\nbreak"))
        #expect(FileListFile.lines(in: Data(text.utf8)) == names)
    }

    @Test func oldListFilesAreReadAsTheyWere() {
        let old = "/a/b.txt\r\nC:\\dir\\file.txt\n  /spaced/path  \n\"half\n\\n/not/an/escape\n\"/with\\q\"\n"
        #expect(
            FileListFile.lines(in: Data(old.utf8)) == [
                "/a/b.txt", "C:\\dir\\file.txt", "/spaced/path", "\"half", "\\n/not/an/escape", "\"/with\\q\""
            ])
    }

    @Test func aHugeListFileIsRefused() throws {
        let memory = MemoryFileSystem()
        let registry = FileSystemRegistry()
        registry.register(memory)
        registry.register(LocalFileSystem())
        registry.register(Review2WatchFileSystem(scheme: "sftp"))
        memory.addFile("/L/big.lst", String(repeating: "/x\n", count: FileListFile.lineLimit + 1))
        #expect(throws: (any Error).self) {
            _ = try FileListFile.read(memory.url("/L/big.lst"), fileSystems: registry, relativeTo: memory.url("/L"))
        }
        memory.addFile("/L/small.lst", "mem:/A/one\n/Users/x/local\nsftp://evil.example/x\n")
        let urls =
            (try? FileListFile.read(memory.url("/L/small.lst"), fileSystems: registry, relativeTo: memory.url("/L")))
            ?? []
        // The file's own file system and local files only: no connection is made for the third line.
        #expect(urls.count == 2 && !urls.contains { $0.scheme == "sftp" })
    }
}

@Suite struct Review2ConfigBPlaces {
    @Test func frequentCountsSaturateAndArePassedThroughAnImportOfTheMaximum() throws {
        let json = #"{"counts":{"file:///Users/x/dir":9223372036854775807,"file:///neg":-5}}"#
        var frequent = try JSONDecoder().decode(FrequentFolders.self, from: Data(json.utf8))
        #expect(frequent.counts["file:///neg"] == 0)
        frequent.record(URL(fileURLWithPath: "/Users/x/dir"))
        #expect(frequent.counts["file:///Users/x/dir"] == Int.max)
    }

    @Test func aStoredHistoryHoldsNoMoreThanItKeeps() throws {
        let visits = (0..<1_000).map { #"{"location":"file:///d\#($0)","isVisible":true}"# }.joined(separator: ",")
        let history = try JSONDecoder().decode(DirectoryHistory.self, from: Data(#"{"visits":[\#(visits)]}"#.utf8))
        #expect(history.visits.count == DirectoryHistory.storedLimit && history.current?.path == "/d999")
        var again = history
        #expect(again.record(URL(fileURLWithPath: "/d999"), stayedInPrevious: false) == false)
        #expect(again.record(URL(fileURLWithPath: "/d900"), stayedInPrevious: false) && again.current?.path == "/d900")
        // Round trip keeps only what was stored, not the cached key.
        let data = try JSONEncoder().encode(again)
        #expect(!String(decoding: data, as: UTF8.self).contains("\"key\""))
    }

    @Test func aPasswordInALocationIsNotStoredInTheHistory() throws {
        var history = DirectoryHistory()
        history.record(try #require(URL(string: "ftp://u:secret@host/dir")), stayedInPrevious: false)
        #expect(history.visits.first?.location.contains("secret") == false)
        var frequent = FrequentFolders()
        frequent.record(try #require(URL(string: "ftp://u:secret@host/dir")))
        #expect(frequent.counts.keys.allSatisfy { !$0.contains("secret") })
    }

    @Test func hotlistEntriesForAwkwardFoldersLeadBackToThem() {
        for path in ["/x/trailing ", " /x/leading", "/x/:", "/x/a:", "/x/\"q\"", "/x/plain"] {
            let command = HotlistAction.changeDirectoryCommand(to: path)
            #expect(HotlistAction(command) == .changeDirectory(path: path, focusingOnIt: false), "\(path)")
        }
        #expect(HotlistAction("cd /x/y/:") == .changeDirectory(path: "/x/y", focusingOnIt: true))
    }

    @Test func treeCacheFilesAreMode0600InAFolderOf0700AndNeverGoBackToAnOlderState() throws {
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        let root = URL(fileURLWithPath: "/Volumes/R2")
        cache.store(["a", "b"], for: root)
        let file = try #require(cache.fileURL(for: root))
        func mode(_ url: URL) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int) ?? -1
        }
        #expect(mode(file) == 0o600 && mode(box.url("cache")) == 0o700)
        // The newest store wins, and what is left is no temporary file.
        for round in 0..<20 { cache.store((0...round).map { "f\($0)" }, for: root) }
        cache.flush()
        #expect(TreeCache(directory: box.url("cache")).paths(for: root)?.count == 20)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: box.url("cache").path).filter {
            $0.contains(".tmp")
        }
        #expect(leftovers.isEmpty)
    }

    @Test func treeCachePathsWithLineBreaksAreLeftOutAndTheTreeCountsAsPartial() throws {
        let root = URL(fileURLWithPath: "/Volumes/R2")
        let text = TreeCache.format(TreeCache.Entry(paths: ["ok", "bad\n[injected]", "fine"]), root: root)
        let entry = try #require(TreeCache.parseEntry(text, root: root))
        #expect(entry.paths == ["ok", "fine"] && !entry.isComplete)
    }

    @Test func treeCacheFileOverTheLimitIsNotRead() throws {
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        let root = URL(fileURLWithPath: "/Volumes/R2")
        let file = try #require(cache.fileURL(for: root))
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = "[" + String(repeating: "x", count: 1_022) + "]\n"
        var text = "root=" + root.absoluteString + "\n"
        text += String(repeating: line, count: TreeCache.fileLimit / line.utf8.count + 10)
        try text.write(to: file, atomically: true, encoding: .utf8)
        #expect(cache.entry(for: root) == nil)
    }
}

@Suite struct Review2ConfigBTree {
    @Test func aScanLeavesProtectedAndCloudFoldersUnreadButAUserOpenedOneIsRead() throws {
        let box = try Sandbox()
        try box.folder("plain/inner")
        let protected = URL(fileURLWithPath: NSHomeDirectory() + "/Library/CloudStorage")
        #expect(TreeScanner.isProtected(protected) && !TreeScanner.isProtected(box.url("plain")))
        #expect(TreeScanner.isProtected(URL(fileURLWithPath: NSHomeDirectory() + "/Documents")))
        let scanner = TreeScanner(root: box.root, provider: LocalFileSystem())
        var names: [String] = []
        scanner.run { levels in names += levels.flatMap(\.children) }
        #expect(names.sorted() == ["inner", "plain"] && scanner.unscanned.isEmpty)
        // Reading the folder itself, as when the user opens it, works whatever it is.
        let own = TreeScanner(root: protected, provider: LocalFileSystem())
        _ = own.subfolders(of: protected)
    }

    @Test func aScanStopsAtItsFolderLimitAndCountsAsIncomplete() throws {
        let box = try Sandbox()
        for index in 0..<20 { try box.folder("d\(index)/sub") }
        let scanner = TreeScanner(root: box.root, provider: LocalFileSystem(), batchSize: 4)
        scanner.folderLimit = 10
        let finished = scanner.run { _ in }
        #expect(!finished && scanner.reachedLimit)
        #expect(!scanner.unscanned.isEmpty)
        let timed = TreeScanner(root: box.root, provider: LocalFileSystem(), batchSize: 4)
        timed.timeLimit = -1
        #expect(!timed.run { _ in } && timed.reachedLimit)
    }

    @Test func gentleScanRestoresTheThreadsPriorities() {
        // On a thread of its own (a pool thread of Dispatch does not take a policy of its own).
        let seen = Mutex<[Int32]>([])
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let before = getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD)
            let inside = TreeScanner.gently { getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD) }
            seen.mutate { $0 = [before, inside, getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD)] }
            done.signal()
        }
        thread.start()
        done.wait()
        let values = seen.value
        #expect(values.count == 3 && values[1] == IOPOL_THROTTLE && values[2] == values[0], "\(values)")
    }

    @Test func quickSearchWorksInSlicesAndMatchesTheBlockingSearch() {
        let root = URL(fileURLWithPath: "/Volumes/R2", isDirectory: true)
        let tree = DirectoryTree(rootURL: root, paths: (0..<5_000).map { "dir\($0)" } + ["needle"])
        let blocking = tree.find("needle", from: nil)
        var progress = tree.search("needle", from: nil, timeBudget: 0)
        var steps = 0
        while case .pending(let node, let left) = progress {
            steps += 1
            progress = tree.search("needle", from: node, includingStart: true, remaining: left, timeBudget: 0)
        }
        guard case .found(let found) = progress else {
            Issue.record("not found")
            return
        }
        #expect(found === blocking && steps >= 1)
        // A name that is nowhere ends with .none, not with a pending slice.
        var missing = tree.search("zzz", from: nil, timeBudget: 0)
        while case .pending(let node, let left) = missing {
            missing = tree.search("zzz", from: node, includingStart: true, remaining: left, timeBudget: 0)
        }
        if case .none = missing {} else { Issue.record("expected no match") }
    }
}

@Suite struct Review2ConfigBTabs {
    let memory = MemoryFileSystem()

    func read(_ text: String) -> TabFile? { TabFile(text: text) { memory.location(from: $0) } }

    @Test func pathsAndCaptionsWithLineBreaksRoundTripWithoutInjectingLines() throws {
        let awkward = memory.url("/tmp/a\n1_path=sftp://evil.example/x")
        let tab = PanelTabs.State.Tab(location: awkward, title: "t\n1_path=/etc")
        let file = TabFile(
            active: PanelTabs.State(
                tabs: [tab, PanelTabs.State.Tab(location: memory.url("/second"), title: " padded ")], active: 0))
        let text = file.text(displayPath: memory.displayPath)
        // No line of the file starts a tab of its own that was not written as one.
        #expect(
            text.split(whereSeparator: \.isNewline).filter {
                $0.hasPrefix("1_path=sftp") || $0.hasPrefix("1_path=/etc")
            }.isEmpty)
        let back = try #require(read(text))
        #expect(back == file)
        #expect(
            back.active.tabs.count == 2 && back.active.tabs[0].title == "t\n1_path=/etc"
                && back.active.tabs[1].title == " padded ")
    }

    @Test func aByteOrderMarkAndUTF16FilesAreRead() throws {
        #expect(read("\u{FEFF}[activetabs]\n0_path=mem:/A\n")?.active.tabs.count == 1)
        let utf16 = try #require("[activetabs]\r\n0_path=mem:/A\r\n".data(using: .utf16))
        #expect(read(TabFile.text(decoding: utf16))?.active.tabs.count == 1)
        let utf8 = Data([0xEF, 0xBB, 0xBF]) + Data("[activetabs]\n0_path=mem:/B\n".utf8)
        #expect(read(TabFile.text(decoding: utf8))?.active.tabs.count == 1)
    }

    @Test func oldTabFilesWithBackslashesAreReadAsTheyStand() {
        let file = read("[activetabs]\n0_path=mem:/C:\\dir\n0_caption=C:\\Work\n")
        #expect(file?.active.tabs.first?.title == "C:\\Work")
    }

    @Test func aTabFileOpensNoMoreThanTheLimit() throws {
        let lines = (0..<5_000).map { "\($0)_path=mem:/d\($0)" }.joined(separator: "\n")
        let file = try #require(read("[activetabs]\n" + lines + "\n"))
        #expect(file.active.tabs.count == TabFile.tabLimit)
        let huge = String(repeating: "x", count: TabFile.pathLimit + 1)
        #expect(read("[activetabs]\n0_path=mem:/\(huge)\n") == nil)
    }
}

@MainActor @Suite struct Review2ConfigBTabLoading {
    let memory = MemoryFileSystem()
    let bench: TestBench

    init() {
        memory.addFile("/A/one.txt")
        memory.addFile("/B/other.txt")
        bench = TestBench(
            plugins: [FolderTabsPlugin()],
            fileSystems: [memory, Review2WatchFileSystem(scheme: "sftp"), Review2WatchFileSystem(scheme: "ftp")],
            left: memory.url("/A"), right: memory.url("/B"))
    }

    @Test func loadingAFileNeverMakesAServerTabTheShownOne() {
        memory.addFile(
            "/B/tabs.tab", "[activetabs]\n0_path=mem:/A\n1_path=sftp://evil.example/x\n2_path=mem:/B\nactivetab=1\n")
        bench.commands.perform("OPENTABS", .location(memory.url("/B/tabs.tab")))
        let tabs = bench.left.tabs
        #expect(tabs.count == 3)
        #expect(tabs.active.directory.scheme == "mem")
        #expect(tabs.tabs[1].directory.scheme == "sftp")
    }

    @Test func aFileWhoseTabsAllConnectLeavesTheShownTabAlone() {
        memory.addFile(
            "/B/tabs.tab", "[activetabs]\n0_path=sftp://evil.example/x\n1_path=ftp://other.example/y\nactivetab=0\n")
        bench.commands.perform("OPENTABS", .location(memory.url("/B/tabs.tab")))
        let tabs = bench.left.tabs
        #expect(tabs.active.directory == memory.url("/A") && tabs.count == 3)
        #expect(tabs.tabs.contains { $0.directory.scheme == "sftp" })
    }

    @Test func loadingManyTabsTellsTheListenerOncePerPanel() {
        let lines = (0..<100).map { "\($0)_path=mem:/A/d\($0)" }.joined(separator: "\n")
        memory.addFile("/B/many.tab", "[activetabs]\n" + lines + "\nactivetab=3\n")
        var changes = 0
        bench.left.tabs.onChange = { changes += 1 }
        bench.commands.perform("OPENTABS", .location(memory.url("/B/many.tab")))
        #expect(bench.left.tabs.count == 100 && changes == 1)
    }

    @Test func aFileWithThousandsOfTabsOpensTheLimit() {
        let lines = (0..<3_000).map { "\($0)_path=mem:/A/d\($0)" }.joined(separator: "\n")
        memory.addFile("/B/huge.tab", "[activetabs]\n" + lines + "\n")
        bench.commands.perform("APPENDTABS", .location(memory.url("/B/huge.tab")))
        #expect(bench.left.tabs.count <= FolderTabsPlugin.tabsPerPanelLimit)
    }
}

@MainActor @Suite struct Review2ConfigBNavigation {
    let memory = MemoryFileSystem()
    private let scratch = ScratchPasteboard()
    var pasteboard: NSPasteboard { scratch.pasteboard }
    let bench: TestBench

    init() {
        memory.addFile("/A/docs/in.txt")
        memory.addFile("/B/other.txt")
        bench = TestBench(
            plugins: [NavigationPlugin(pasteboard: scratch.pasteboard, home: memory.url("/home"))],
            fileSystems: [memory],
            left: memory.url("/A"), right: memory.url("/B"))
    }

    @Test func goingToANeighbourVolumeAsksTheDisksInAJob() {
        bench.commands.perform("cm_GoToNextDrive")
        #expect(bench.jobService.titles == ["Go to volume"])
        #expect(bench.left.model.directory == memory.url("/"))
    }

    @Test func theClipboardIsAskedOnlyWhenItsChangeCountChanged() {
        pasteboard.clearContents()
        #expect(!bench.commands.isEnabled("afm_CdFromClipboard"))
        // Without a change the answer stays, whatever the menus ask.
        for _ in 0..<5 { #expect(!bench.commands.isEnabled("afm_CdFromClipboard")) }
        pasteboard.setString("/x", forType: .string)
        #expect(bench.commands.isEnabled("afm_CdFromClipboard"))
        pasteboard.clearContents()
        #expect(!bench.commands.isEnabled("afm_CdFromClipboard"))
    }
}

/// A small lock around a value, for results written by callbacks on other threads.
/// Unchecked: the state is guarded by `lock`.
private final class Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func mutate(_ change: (inout Value) -> Void) {
        lock.lock()
        change(&stored)
        lock.unlock()
    }
}

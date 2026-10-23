import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import VirtualFoldersPlugin

/// The virtual file system of lists and branches (review 2): its watchers, its limits and its names.
@Suite
internal struct Review2ConfigBVirtualFileSystem {
    /// The registry is freed with the virtual file system registered in it.
    @Test
    internal func theRegistryGoesWithTheFileSystemsInIt() {
        weak var gone: FileSystemRegistry?
        do {
            let registry = FileSystemRegistry()
            registry.register(VirtualFileSystem(fileSystems: registry))
            gone = registry
        }
        #expect(gone == nil)
    }

    /// A watcher's reports reach the caller on the main thread, whichever thread fires them.
    @Test
    internal func watcherReportsReachTheCallerOnTheMainThreadWhicheverThreadFiresThem() async {
        let provider = Review2WatchFileSystem()
        let registry = FileSystemRegistry()
        registry.register(provider)
        let virtual = VirtualFileSystem(fileSystems: registry)
        let list = virtual.register(files: [provider.url("/top/sub/f.txt")], title: "L", origin: nil)
        let threads = Shared<[Bool]>([])
        let watcher = virtual.watch([list]) { _ in threads.modify { $0.append(Thread.isMainThread) } }
        #expect(watcher != nil)
        // From a background thread, as a file system's own queue would.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global()
                .async {
                    provider.fire()
                    continuation.resume()
                }
        }
        await PanelWait.drainMainQueue()
        #expect(threads.value == [true])
        withExtendedLifetime(watcher) {
            // The watcher is kept until the reports have been looked at.
        }
    }

    /// A report held back while the watcher is released goes nowhere.
    @Test
    internal func aReportAfterTheWatcherWasReleasedGoesNowhere() async throws {
        let provider = Review2WatchFileSystem()
        let registry = FileSystemRegistry()
        registry.register(provider)
        let virtual = VirtualFileSystem(fileSystems: registry)
        let list = virtual.register(files: [provider.url("/top/f.txt")], title: "L", origin: nil)
        let count = Shared<Int>(0)
        var watcher = virtual.watch([list]) { _ in count.modify { $0 += 1 } }
        provider.fire()
        await PanelWait.drainMainQueue()
        #expect(count.value == 1)
        // A second report within the window is held back; releasing the watcher drops it.
        provider.fire()
        watcher = nil
        try await Task.sleep(nanoseconds: 1_300_000_000)
        await PanelWait.drainMainQueue()
        #expect(count.value == 1)
        _ = watcher
    }

    /// A huge list is prepared in the background and watched in at most the limit of folders.
    @Test
    internal func aHugeListIsRegisteredWithoutWorkOnTheCallerAndWatchedByAtMostTheLimit() {
        let provider = Review2WatchFileSystem()
        let registry = FileSystemRegistry()
        registry.register(provider)
        let virtual = VirtualFileSystem(fileSystems: registry)
        // 20,000 files in as many folders; twice named files are one.
        let files = (0..<20_000).map { provider.url("/d\($0)/f.txt") } + [provider.url("/d1/f.txt")]
        let list = virtual.register(files: files, title: "Many", origin: nil)
        let watcher = virtual.watch([list]) { _ in
            // Only the watching itself matters here.
        }
        #expect(watcher != nil)
        #expect(provider.watchedCount <= VirtualFileSystem.watchLimit)
        // Waits for the background preparation: every file once.
        #expect(virtual.entries(of: list)?.count == 20_000)
        #expect(virtual.volume(of: list)?.isLocal == false)
    }

    /// Files whose names differ only in Unicode normalisation are two files in a list.
    @Test
    internal func filesThatDifferOnlyInUnicodeNormalisationAreTwoFilesInAList() throws {
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

    /// Names in a selected branch never clash, also when paths read alike.
    @Test
    internal func namesInASelectedBranchNeverClash() {
        let items = [
            FileItem(url: URL(fileURLWithPath: "/a/x.txt"), name: "x.txt"),
            FileItem(url: URL(fileURLWithPath: "/b/x.txt"), name: "x.txt"),
            FileItem(url: URL(fileURLWithPath: "/c/y"), name: "y"),
            FileItem(url: URL(fileURLWithPath: "/d/y"), name: "y")
        ]
        // Two paths that read alike are told apart as well.
        let names = VirtualFileSystem.uniqueNames(of: items) { _ in "same" }
        #expect(names == ["same", "same (2)", "same (3)", "same (4)"])
        let plain = VirtualFileSystem.uniqueNames(of: items) { $0.url.path }
        #expect(plain == ["/a/x.txt", "/b/x.txt", "/c/y", "/d/y"])
    }

    /// When there are too many lists, the one left alone longest goes first.
    @Test
    internal func leastRecentlyUsedUnwatchedListGoesFirst() {
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

    /// The capabilities without a location claim nothing that a folder shown before cannot do.
    @Test
    internal func capabilitiesWithoutALocationClaimNothingAnyShownFolderCannotDo() throws {
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

    /// The real location of a branch item is the real file; lists have none.
    @Test
    internal func realLocationOfABranchItemIsTheRealFile() {
        let registry = FileSystemRegistry()
        let virtual = VirtualFileSystem(fileSystems: registry)
        let real = URL(fileURLWithPath: "/Users/x/dir/a.txt")
        #expect(virtual.realLocation(of: VirtualLocation.branch(of: real).url) == real)
        #expect(virtual.realLocation(of: real) == nil)
        #expect(virtual.realLocation(of: VirtualLocation.list(id: 1, title: "T", origin: nil).url) == nil)
    }

    /// A typed list location leads to the list only with the list's own title.
    @Test
    internal func aTypedListNoteNeedsTheListsOwnTitle() {
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

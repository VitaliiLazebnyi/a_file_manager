import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import VirtualFoldersPlugin

/// Watching virtual folders, and lists asked about while they are still being worked through.
@MainActor
@Suite
internal struct CoverageVirtualWatching {
    /// The real files: `/A` with two files.
    private let memory = MemoryFileSystem()
    /// The memory files behind a layer that can watch and hold a thread.
    private let files: CoverageSmallFiles
    /// The file systems, the virtual one among them.
    private let fileSystems = FileSystemRegistry()
    /// The file system under test.
    private let virtual: VirtualFileSystem

    /// The files and the registry.
    internal init() {
        memory.addFile("/A/one.txt", "1")
        memory.addFile("/A/two.txt", "2")
        files = CoverageSmallFiles(memory)
        files.watches = true
        fileSystems.register(files)
        virtual = VirtualFileSystem(fileSystems: fileSystems)
        fileSystems.register(virtual)
    }

    /// A branch that was never read is watched at its root; a selected branch and a list are
    /// watched at their folders; a forgotten list, a foreign location and folders that cannot
    /// be watched give no token.
    @Test
    internal func whatIsWatched() {
        let branch = VirtualLocation.branch(of: memory.url("/A")).url
        let picked = virtual.registerPicked([memory.url("/A/one.txt")], in: memory.url("/A"))
        let token = virtual.watch([branch, picked, memory.url("/A")]) { _ in
            // Nothing is reported here.
        }
        #expect(token != nil && files.watchCount == 2)
        let gone = VirtualLocation.list(id: 3, title: "Gone", origin: nil).url
        let none = virtual.watch([gone]) { _ in
            // Nothing is reported here.
        }
        #expect(none == nil)
        files.watches = false
        let unwatched = virtual.watch([branch]) { _ in
            // Nothing is reported here.
        }
        #expect(unwatched == nil)
        withExtendedLifetime(token) {
            // Kept until here.
        }
    }

    /// A list watched twice stays remembered until both watches end; a report after the end
    /// goes nowhere.
    @Test
    internal func aListWatchedTwiceAndReportsAfterTheEnd() async {
        let list = virtual.register(files: [memory.url("/A/one.txt")], title: "Found", origin: nil)
        let reports = Shared(0)
        var first = virtual.watch([list]) { _ in reports.modify { $0 += 1 } }
        var second = virtual.watch([list]) { _ in reports.modify { $0 += 1 } }
        #expect(first != nil && second != nil)
        files.report([memory.url("/A")])
        #expect(reports.value == 2)
        first = nil
        second = nil
        files.report([memory.url("/A")])
        // Released: nothing more arrives, also not later from the main queue.
        try? await Task.sleep(nanoseconds: 1_000_000)
        #expect(reports.value == 2 && first == nil && second == nil)
        #expect(virtual.entries(of: list) == [memory.url("/A/one.txt")])
    }

    /// A watch that outlives its file system ends without it.
    @Test
    internal func aWatchOutlivesItsFileSystem() {
        let registry = FileSystemRegistry()
        registry.register(files)
        var shortLived: VirtualFileSystem? = VirtualFileSystem(fileSystems: registry)
        let list = shortLived?.register(files: [memory.url("/A/one.txt")], title: "Found", origin: nil)
        var token = list.flatMap { url in shortLived?.watch([url]) { _ in /* nothing */ } }
        weak let gone = shortLived
        shortLived = nil
        #expect(gone == nil && token != nil)
        token = nil
        #expect(token == nil)
    }

    /// A long list that is still being worked through is judged by its first file, and its
    /// folders to watch are found from its first files.
    @Test
    internal func aListStillBeingWorkedThroughIsJudgedByItsFirstFiles() {
        let entered = Shared(false)
        let release = DispatchSemaphore(value: 0)
        files.onCall = { call in
            guard call == .parent, !Thread.isMainThread, !entered.value else {
                return
            }
            entered.value = true
            release.wait()
        }
        let urls = (0...VirtualFileSystem.inlineEntryLimit).map { memory.url("/A/f\($0).txt") }
        let list = virtual.register(files: urls, title: "Long", origin: nil)
        #expect(Wait.until { entered.value })
        #expect(virtual.capabilities(for: list).contains(.removeOnly))
        #expect(virtual.volume(of: list)?.isLocal == false)
        let token = virtual.watch([list]) { _ in
            // Nothing is reported here.
        }
        #expect(token != nil)
        release.signal()
        #expect(virtual.entries(of: list)?.count == urls.count)
    }
}

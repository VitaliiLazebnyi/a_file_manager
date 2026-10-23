import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import MultiRenamePlugin

/// The cache of the previews and the store of the runs that can be undone.
extension MultiRenameFixes {
    // MARK: Cache

    /// A cached preview gives the answer a fresh one gives, as far as the folders stay as they were.
    @Test
    internal func aCachedPreviewGivesTheSameAnswer() throws {
        let box = try Sandbox()
        for name in ["a.txt", "b.txt", "c.txt"] {
            try box.file(name)
        }
        let registry = FileSystemRegistry()
        registry.register(LocalFileSystem())
        let entries = ["a.txt", "b.txt", "c.txt"]
            .map { name in
                RenameEntry(FileItem(url: box.url(name), name: name))
            }
        var settings = RenameSettings()
        settings.nameMask = "b"
        let cache = RenameCache()
        let first = RenameComputation.preview(
            RenameRequest(entries: entries, settings: settings, context: context),
            fileSystems: registry,
            cache: cache,
            cancellation: nil
        ) { false }
        // The folder changes behind the cache's back: only a fresh look sees it.
        try box.file("d.txt")
        settings.nameMask = "d"
        let second = RenameComputation.preview(
            RenameRequest(entries: entries, settings: settings, context: context),
            fileSystems: registry,
            cache: cache,
            cancellation: nil
        ) { false }
        let fresh = RenameComputation.preview(
            RenameRequest(entries: entries, settings: settings, context: context),
            fileSystems: registry,
            cache: RenameCache(),
            cancellation: nil
        ) { false }
        #expect(first.statuses == [.duplicate, .unchanged, .duplicate] || first.statuses.contains(.duplicate))
        #expect(second.statuses.allSatisfy { $0 == .duplicate })
        #expect(fresh.statuses.allSatisfy { $0 == .duplicate })
        let cancelled = RenameComputation.preview(
            RenameRequest(entries: entries, settings: settings, context: context),
            fileSystems: registry,
            cache: cache,
            cancellation: nil
        ) { true }
        #expect(cancelled.names.count == 3)
    }

    // MARK: Store

    /// The undo history lives in memory, is saved when it is flushed, and is cheap to count.
    @MainActor
    @Test
    internal func undoHistoryLivesInMemoryAndIsSaved() {
        let settings = MemorySettings()
        let store = RenameStore(settings: settings)
        let run = (0..<5_000)
            .map { index in
                RenamedItem(
                    from: URL(fileURLWithPath: "/d/\(index)"),
                    destination: URL(fileURLWithPath: "/d/n\(index)")
                )
            }
        store.appendUndo(run)
        store.appendUndo([run[0]])
        #expect(store.undoCount == 2 && store.lastUndo.count == 1)
        // Another store on the same settings sees it at once, and so does a fresh decode of the saved copy.
        #expect(RenameStore(settings: settings).undoCount == 2)
        store.flush()
        #expect(settings.value([[RenamedItem]].self, forKey: "multirename.undo")?.map(\.count) == [5_000, 1])
        store.replaceLastUndo(with: [])
        #expect(store.undoCount == 1)
        let start = ThreadTime.used
        for _ in 0..<10_000 {
            _ = store.undoCount
        }
        #expect(ThreadTime.used - start < 1)
        let before = store.revision
        store.remember("[N]", in: .nameMask)
        #expect(store.revision == before + 1 && store.history(.nameMask) == ["[N]"])
    }

    /// The saved undo history is held to its limit: a run that does not fit ends it.
    @Test
    internal func persistedUndoIsCapped() async {
        let settings = MemorySettings()
        let store = await MainActor.run { RenameStore(settings: settings) }
        let big = (0..<(RenameStore.persistedItemLimit - 10))
            .map { index in
                RenamedItem(
                    from: URL(fileURLWithPath: "/d/\(index)"),
                    destination: URL(fileURLWithPath: "/d/n\(index)")
                )
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

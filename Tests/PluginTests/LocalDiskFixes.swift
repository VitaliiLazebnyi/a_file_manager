import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// Locked files, failed copies, special files, large folders, sizes, places and watchers on the local disks.
@Suite
internal struct LocalDiskFixes {
    /// The local disks with the system's own probes, as the program uses them.
    internal let local = LocalFileSystem()

    private func flags(_ url: URL) -> UInt32 {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_flags : 0
    }

    /// A locked file is copied under a temporary name and renamed, and the copy is locked like its source.
    @Test
    internal func aLockedFileIsCopiedUnderATemporaryNameAndRenamed() throws {
        let box = try Sandbox()
        let source = try box.file("locked.txt", "content")
        #expect(chflags(source.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { for name in ["locked.txt", "copy.txt", "second.txt", "other.txt"] { chflags(box.url(name).path, 0) } }
        // What a copy job does: copy to a temporary name, then give it the real one.
        let temporary = box.url(".afm-test.tmp")
        try local.copy(source, to: temporary) { _ in true }
        try local.move(temporary, to: box.url("copy.txt"), replacing: false)
        #expect(!box.exists(".afm-test.tmp") && box.read("copy.txt") == "content")
        // The copy ends up locked like the file it came from, which is still locked itself.
        #expect(flags(box.url("copy.txt")) & UInt32(UF_IMMUTABLE) != 0 && flags(source) & UInt32(UF_IMMUTABLE) != 0)

        // A copy that is given up can be taken away again.
        try local.copy(source, to: temporary) { _ in true }
        try local.remove(temporary)
        #expect(!box.exists(".afm-test.tmp"))

        // Replacing an existing file works the same way.
        try box.file("second.txt", "old")
        try local.copy(source, to: temporary) { _ in true }
        try local.move(temporary, to: box.url("second.txt"), replacing: true)
        #expect(box.read("second.txt") == "content" && flags(box.url("second.txt")) & UInt32(UF_IMMUTABLE) != 0)

        // Files that were locked by someone else stay as locked as they were: neither the
        // source nor a finished copy can be renamed or removed.
        #expect(throws: (any Error).self) { try local.move(source, to: box.url("other.txt"), replacing: false) }
        #expect(throws: (any Error).self) { try local.remove(source) }
        #expect(throws: (any Error).self) { try local.remove(box.url("copy.txt")) }
        #expect(throws: (any Error).self) {
            try local.move(box.url("copy.txt"), to: box.url("other.txt"), replacing: false)
        }
        #expect(box.exists("locked.txt") && box.exists("copy.txt") && !box.exists("other.txt"))
    }

    /// A copy onto an existing file fails and leaves that file alone, and a stopped copy leaves nothing behind.
    @Test
    internal func aFailedCopyLeavesAnExistingFileAlone() throws {
        let box = try Sandbox()
        let source = try box.file("a.txt", "new")
        try box.file("b.txt", "theirs")
        #expect {
            try local.copy(source, to: box.url("b.txt")) { _ in true }
        } throws: { error in
            if case FileSystemError.alreadyExists = error {
                return true
            }
            return false
        }
        #expect(box.read("b.txt") == "theirs")
        // A copy that is stopped leaves nothing behind.
        let big = box.url("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: Data(count: 8 << 20))
        try? local.copy(big, to: box.url("big-copy.bin")) { _ in false }
        #expect(
            !box.exists("big-copy.bin")
                || (try? FileManager.default.attributesOfItem(atPath: box.url("big-copy.bin").path)[.size] as? Int) == 8
                    << 20
        )
    }

    /// Pipes and links to them are special, in a listing and asked for alone; files, folders and other links are not.
    @Test
    internal func pipesAndTheLikeAreToldFromFiles() throws {
        let box = try Sandbox()
        try box.file("plain.txt")
        try box.folder("folder")
        #expect(mkfifo(box.url("pipe").path, 0o644) == 0)
        try FileManager.default.createSymbolicLink(at: box.url("to-pipe"), withDestinationURL: box.url("pipe"))
        try FileManager.default.createSymbolicLink(at: box.url("to-file"), withDestinationURL: box.url("plain.txt"))
        try FileManager.default.createSymbolicLink(at: box.url("to-nothing"), withDestinationURL: box.url("missing"))
        let listed = Dictionary(
            uniqueKeysWithValues: try local.list(box.root, showHidden: true).map { ($0.name, $0) }
        )
        #expect(listed.filter(\.value.isSpecial).keys.sorted() == ["pipe", "to-pipe"])
        for name in listed.keys {
            #expect(local.item(at: box.url(name))?.isSpecial == listed[name]?.isSpecial, "\(name)")
        }
        // Other file systems know no such things, and say so by default.
        #expect(!FileItem(url: box.url("x"), name: "x").isSpecial)
    }

    /// A folder large enough to be listed on several threads gives the same items as asking for each alone.
    @Test
    internal func aLargeFolderIsListedLikeASmallOne() throws {
        // Enough entries for the items to be made on several threads.
        let box = try Sandbox()
        let files = FileManager.default
        for index in 0..<1_500 {
            files.createFile(atPath: box.url("file \(index) é#%.txt").path, contents: Data(count: index % 7))
        }
        for name in ["Some.app", "second.APP", "plain", "dotted.folder", "v1.2", ".hidden.d", "notes.rtfd"] {
            try box.folder(name)
        }
        try files.createSymbolicLink(at: box.url("link.app"), withDestinationURL: box.url("Some.app"))
        let items = try local.list(box.root, showHidden: true)
        #expect(items.count == 1_508 && Set(items.map(\.name)).count == 1_508)
        for item in items {
            // Every item is what asking for it alone gives, location and all.
            #expect(item == local.item(at: box.root.appending(name: item.name)), "\(item.name)")
            #expect(
                item.url == box.root.appending(name: item.name)
                    && item.url.absoluteString == box.root.appending(name: item.name).absoluteString
            )
        }
        let packages = Set(items.filter(\.isPackage).map(\.name))
        #expect(packages == ["Some.app", "second.APP", "notes.rtfd"])
        // Asked again, with what was learned about the extensions, the answers are the same.
        #expect(Set(try local.list(box.root, showHidden: true).filter(\.isPackage).map(\.name)) == packages)
        #expect(try local.list(box.root, showHidden: false).count == 1_507)
    }

    /// A tree's total size is the same measured directly as added up from its listings, and nothing when cancelled.
    @Test
    internal func aTreeIsMeasuredLikeItIsListed() throws {
        let box = try Sandbox()
        for folder in 0..<12 {
            for file in 0..<20 {
                try box.file(
                    "d\(folder)/sub\(file % 3)/f\(file).bin",
                    String(repeating: "x", count: folder * 10 + file)
                )
            }
        }
        try box.file(".hidden/secret", "12345")
        try FileManager.default.createSymbolicLink(at: box.url("link"), withDestinationURL: box.url("d1"))
        let byListing = local.totalSizeByListing(of: box.root, cancellation: CancellationFlag())
        let written = (0..<12).reduce(5) { sum, folder in (0..<20).reduce(sum) { $0 + folder * 10 + $1 } }
        #expect(byListing == Int64(written))
        #expect(local.totalSize(of: box.root, cancellation: CancellationFlag()) == byListing)
        let provider: any FileSystemProvider = local
        #expect(
            provider.totalSize(of: box.root, cancellation: CancellationFlag()) == byListing
                && provider.totalSize(of: box.root, cancellation: CancellationFlag()) == byListing
        )
        #expect(local.totalSize(of: box.url("missing"), cancellation: CancellationFlag()) == 0)
        let cancelled = CancellationFlag()
        cancelled.cancel()
        #expect(local.totalSize(of: box.root, cancellation: cancelled) == 0)
    }

    /// The places come from memory once known, and a volume's free space is first measured and then worked out.
    @Test
    internal func placesAndVolumesAnswerFromWhatIsKnown() throws {
        let places = local.settledPlaces()
        #expect(places.first?.kind == .home && places.contains { $0.kind == .internalDisk && $0.url.path == "/" })
        // Asked again, the list comes from memory (`places()` only reads what is known).
        for _ in 0..<200 { #expect(local.places().map(\.url) == places.map(\.url)) }

        // The free space of a volume is the figure the system gives for important uses,
        // first measured and then worked out from the plainly free space. The figures are the
        // probe's: the disk's own change all the time while other tests write.
        let figures = Shared((available: Int64(10 << 30), important: Int64(15 << 30)))
        var probes = LocalProbes()
        probes.freeSpace = { _ in
            let now = figures.value
            return (Int64?(now.available), Int64?(now.important))
        }
        let probed = LocalFileSystem(probes: probes)
        let sandbox = try box()
        let first = try #require(probed.volume(of: sandbox.root))
        #expect(first.freeBytes == 15 << 30 && !first.name.isEmpty && first.isLocal)
        // A gigabyte written since, and a figure for important uses that is not asked for: the
        // next answer is the plainly free space plus what the system would clear, as measured.
        figures.value = (available: 9 << 30, important: 99 << 30)
        let second = try #require(probed.volume(of: sandbox.root))
        #expect(second.freeBytes == 14 << 30)
        #expect(second.name == first.name && second.totalBytes == first.totalBytes && second.isLocal)
    }

    private func box() throws -> Sandbox { try Sandbox() }

    /// A watcher let go while changes arrive in its folder does no harm.
    @Test
    internal func aWatcherThatGoesAwayWhileChangesArriveDoesNoHarm() async throws {
        let box = try Sandbox()
        try box.folder("watched")
        for round in 0..<20 {
            // Made here, not on the main thread: the watch returns at once from any thread, and twenty turns of a
            // main thread that every other test wants took this test two minutes of a full run.
            let watcher = local.watch([box.url("watched")]) { _ in
                // The changes themselves do not matter here.
            }
            try box.file("watched/\(round).txt")
            try await Task.sleep(nanoseconds: UInt64(round % 4) * 150_000_000)
            withExtendedLifetime(watcher) {
                // The watcher lives until here.
            }
        }
    }
}

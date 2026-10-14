import AFMContracts
import AFMKernel
import AppKit
import Foundation
import NavigationPlugin
import TestSupport
import Testing

@testable import FolderTabsPlugin
@testable import LocalFileSystemPlugin
@testable import ViewOptionsPlugin

@Suite struct LocalDiskFixes {
    let local = LocalFileSystem()

    private func flags(_ url: URL) -> UInt32 {
        var st = stat()
        return lstat(url.path, &st) == 0 ? st.st_flags : 0
    }

    @Test func aLockedFileIsCopiedUnderATemporaryNameAndRenamed() throws {
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

    @Test func aFailedCopyLeavesAnExistingFileAlone() throws {
        let box = try Sandbox()
        let source = try box.file("a.txt", "new")
        try box.file("b.txt", "theirs")
        #expect {
            try local.copy(source, to: box.url("b.txt")) { _ in true }
        } throws: { error in
            if case FileSystemError.alreadyExists = error { return true }
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

    @Test func pipesAndTheLikeAreToldFromFiles() throws {
        let box = try Sandbox()
        try box.file("plain.txt")
        try box.folder("folder")
        #expect(mkfifo(box.url("pipe").path, 0o644) == 0)
        try FileManager.default.createSymbolicLink(at: box.url("to-pipe"), withDestinationURL: box.url("pipe"))
        try FileManager.default.createSymbolicLink(at: box.url("to-file"), withDestinationURL: box.url("plain.txt"))
        try FileManager.default.createSymbolicLink(at: box.url("to-nothing"), withDestinationURL: box.url("missing"))
        let listed = Dictionary(
            uniqueKeysWithValues: try local.list(box.root, showHidden: true).map { ($0.name, $0) })
        #expect(listed.filter(\.value.isSpecial).keys.sorted() == ["pipe", "to-pipe"])
        for name in listed.keys {
            #expect(local.item(at: box.url(name))?.isSpecial == listed[name]?.isSpecial, "\(name)")
        }
        // Other file systems know no such things, and say so by default.
        #expect(!FileItem(url: box.url("x"), name: "x", isDirectory: false).isSpecial)
    }

    @Test func aLargeFolderIsListedLikeASmallOne() throws {
        // Enough entries for the items to be made on several threads.
        let box = try Sandbox()
        let fm = FileManager.default
        for index in 0..<1500 {
            fm.createFile(atPath: box.url("file \(index) é#%.txt").path, contents: Data(count: index % 7))
        }
        for name in ["Some.app", "second.APP", "plain", "dotted.folder", "v1.2", ".hidden.d", "notes.rtfd"] {
            try box.folder(name)
        }
        try fm.createSymbolicLink(at: box.url("link.app"), withDestinationURL: box.url("Some.app"))
        let items = try local.list(box.root, showHidden: true)
        #expect(items.count == 1508 && Set(items.map(\.name)).count == 1508)
        for item in items {
            // Every item is what asking for it alone gives, location and all.
            #expect(item == local.item(at: box.root.appending(name: item.name)), "\(item.name)")
            #expect(
                item.url == box.root.appending(name: item.name)
                    && item.url.absoluteString == box.root.appending(name: item.name).absoluteString)
        }
        let packages = Set(items.filter(\.isPackage).map(\.name))
        #expect(packages == ["Some.app", "second.APP", "notes.rtfd"])
        // Asked again, with what was learned about the extensions, the answers are the same.
        #expect(Set(try local.list(box.root, showHidden: true).filter(\.isPackage).map(\.name)) == packages)
        #expect(try local.list(box.root, showHidden: false).count == 1507)
    }

    @Test func aTreeIsMeasuredLikeItIsListed() throws {
        let box = try Sandbox()
        for folder in 0..<12 {
            for file in 0..<20 {
                try box.file(
                    "d\(folder)/sub\(file % 3)/f\(file).bin", String(repeating: "x", count: folder * 10 + file))
            }
        }
        try box.file(".hidden/secret", "12345")
        try FileManager.default.createSymbolicLink(at: box.url("link"), withDestinationURL: box.url("d1"))
        let byListing = local.totalSizeByListing(of: box.root, cancellation: CancellationFlag())
        #expect(byListing == (0..<12).reduce(5) { sum, folder in (0..<20).reduce(sum) { $0 + folder * 10 + $1 } }.int64)
        #expect(local.totalSize(of: box.root) == byListing)
        let provider: FileSystemProvider = local
        #expect(
            provider.totalSize(of: box.root, cancellation: CancellationFlag()) == byListing
                && provider.totalSize(of: box.root) == byListing)
        #expect(local.totalSize(of: box.url("missing")) == 0)
        let cancelled = CancellationFlag()
        cancelled.cancel()
        #expect(local.totalSize(of: box.root, cancellation: cancelled) == 0)
    }

    @Test func placesAndVolumesAnswerFromWhatIsKnown() throws {
        let places = local.settledPlaces()
        #expect(places.first?.kind == .home && places.contains { $0.kind == .internalDisk && $0.url.path == "/" })
        // Asked again, the list comes from memory, at once.
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<200 { #expect(local.places().count == places.count) }
        #expect(DispatchTime.now().uptimeNanoseconds - start < 1_000_000_000)

        // The free space of a volume is the figure the system gives for important uses,
        // first measured and then worked out from the plainly free space.
        let root = URL(fileURLWithPath: "/")
        let first = try #require(local.volume(of: root))
        let second = try #require(local.volume(of: box().root))
        let measured =
            try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? 0
        #expect(first.name == second.name || !first.name.isEmpty)
        for volume in [first, try #require(local.volume(of: root))] where measured > 0 {
            // Other programs write while this runs; a gigabyte is far below any real mistake.
            #expect(abs((volume.freeBytes ?? 0) - measured) < 1 << 30)
            #expect(volume.totalBytes == first.totalBytes && volume.isLocal == first.isLocal)
        }
    }

    private func box() throws -> Sandbox { try Sandbox() }

    @Test func aWatcherThatGoesAwayWhileChangesArriveDoesNoHarm() async throws {
        let box = try Sandbox()
        try box.folder("watched")
        for round in 0..<20 {
            let watcher = await MainActor.run { local.watch([box.url("watched")]) { _ in } }
            try box.file("watched/\(round).txt")
            try await Task.sleep(nanoseconds: UInt64(round % 4) * 150_000_000)
            withExtendedLifetime(watcher) {}
        }
    }
}

extension Int {
    fileprivate var int64: Int64 { Int64(self) }
}

@MainActor @Suite struct PluginFixes {
    let memory = MemoryFileSystem()
    let pasteboard = NSPasteboard.withUniqueName()
    let bench: TestBench

    init() {
        memory.addFile("/A/one.txt", "1")
        memory.addFile("/A/docs/in.txt", "inside")
        memory.addFile("/B/other.txt", "o")
        bench = TestBench(
            plugins: [FolderTabsPlugin(), NavigationPlugin(pasteboard: pasteboard), ViewOptionsPlugin()],
            fileSystems: [memory],
            left: memory.url("/A"), right: memory.url("/B"))
    }

    @Test func aTabFileIsReplacedInOneStepAndOnlyIfItIsAFile() {
        bench.commands.perform("SAVETABS", .location(memory.url("/A/my.tab")))
        let first = memory.contents("/A/my.tab")
        #expect(first?.contains("[activetabs]") == true)
        // Saving again replaces the file, and nothing temporary is left beside it.
        bench.left.tabs.openTab(showing: memory.url("/A/docs"), activate: true)
        bench.ui.choiceAnswers = [0]
        bench.commands.perform("SAVETABS", .location(memory.url("/A/my.tab")))
        #expect(memory.contents("/A/my.tab") != first && memory.contents("/A/my.tab")?.contains("docs") == true)
        #expect(
            (try? memory.list(memory.url("/A"), showHidden: true).map(\.name).sorted()) == [
                "docs", "my.tab", "one.txt"
            ])
        // A folder of that name is not a tab file: it is neither removed nor read.
        memory.addDirectory("/A/folder.tab")
        bench.commands.perform("SAVETABS", .location(memory.url("/A/folder.tab")))
        #expect(memory.item(at: memory.url("/A/folder.tab"))?.isDirectory == true)
        #expect(bench.ui.log.last?.contains("could not be saved") == true)
    }

    @Test func aFileTooLargeToBeATabFileIsNotLoaded() {
        memory.addFile("/A/huge.tab", String(repeating: "x", count: FolderTabsPlugin.tabFileLimit + 10))
        let before = bench.left.tabs.count
        bench.commands.perform("OPENTABS", .location(memory.url("/A/huge.tab")))
        #expect(bench.left.tabs.count == before && bench.ui.log.last?.contains("could not be loaded") == true)
    }

    @Test func theClipboardCommandIsOfferedForAnyTextAndReadsOnlyTheFirstLine() {
        #expect(!bench.commands.isEnabled("afm_CdFromClipboard"))
        pasteboard.clearContents()
        pasteboard.setString(
            "\n\n  mem:/A/docs  \n" + String(repeating: "more lines\n", count: 50_000), forType: .string)
        #expect(bench.commands.isEnabled("afm_CdFromClipboard"))
        bench.commands.perform("afm_CdFromClipboard")
        #expect(bench.left.model.directory.path == "/A/docs")
    }

    @Test func aLongListIsSortedInTheBackgroundAndAShortOneAtOnce() async throws {
        let model = bench.left.model
        bench.commands.perform("cm_SrcBySize")
        #expect(model.sort == ListOrder(key: .size, descending: true))

        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let long = (0..<(ViewOptionsPlugin.backgroundSortThreshold + 500)).map {
            FileItem(url: memory.url("/A/f\($0).txt"), name: "f\($0).txt", isDirectory: false, size: Int64($0 % 977))
        }
        model.show(Listing(directory: memory.url("/A"), items: long, parent: root, root: root))
        bench.commands.perform("cm_SrcByName")
        // Two commands in a row: the second starts from the order the first is on its way to.
        bench.commands.perform("cm_SrcNegOrder")
        for _ in 0..<200 where model.sort != ListOrder(key: .name, descending: true) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(model.sort == ListOrder(key: .name, descending: true))
        #expect(model.items == Sorter.sort(long, by: ListOrder(key: .name, descending: true)))
    }
}

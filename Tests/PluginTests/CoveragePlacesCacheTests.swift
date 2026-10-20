import AFMKernel
import Darwin
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import PlacesPlugin

/// The tree cache when its files cannot be written as asked: a write that comes late, a tree
/// too big for a file, a temporary file that is in the way, a disk that refuses the data.
@Suite(.serialized) struct CoveragePlacesCacheFiles {
    let root = URL(fileURLWithPath: "/Volumes/Disk", isDirectory: true)
    let other = URL(fileURLWithPath: "/Volumes/Other", isDirectory: true)

    /// Where the cache writes the file of `root` before it takes the file's place.
    func temporary(of file: URL) -> String { file.path + ".tmp\(getpid())" }

    /// Reads everything from the FIFO at `path` until the writer closes it.
    func drain(_ descriptor: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        close(descriptor)
        return data
    }

    /// Paths that make a file of about `megabytes` megabytes.
    func bulky(_ megabytes: Int, prefix: String = "p") -> [String] {
        let tail = String(repeating: "x", count: 1_000)
        return (0..<(megabytes * 1_040)).map { "\(prefix)\($0)/\(tail)" }
    }

    @Test func aWriteThatWasOvertakenIsNotMade() throws {
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        cache.store(["warm-up"], for: root)
        let blockerFile = try #require(cache.fileURL(for: root))
        let fifo = temporary(of: blockerFile)
        #expect(mkfifo(fifo, 0o600) == 0)
        let group = DispatchGroup()
        // The first write stops in the FIFO, holding the cache's write lock, until it is read.
        let big = bulky(4)
        group.enter()
        OtherThread.start {
            cache.store(big, for: root)
            group.leave()
        }
        let reader = open(fifo, O_RDONLY)
        #expect(reader >= 0)
        // Two stores of another tree come while it waits: the first is overtaken by the second.
        group.enter()
        OtherThread.start {
            cache.store(["first"], for: other)
            group.leave()
        }
        #expect(Wait.until { cache.paths(for: other) == ["first"] })
        group.enter()
        OtherThread.start {
            cache.store(["second"], for: other)
            group.leave()
        }
        #expect(Wait.until { cache.paths(for: other) == ["second"] })
        let written = drain(reader)
        group.wait()
        #expect(written == Data(TreeCache.format(big, root: root).utf8))
        let otherFile = try #require(cache.fileURL(for: other))
        #expect(TreeCache.parse(try String(contentsOf: otherFile, encoding: .utf8), root: other) == ["second"])
    }

    @Test func aTreeTooBigForAFileRemovesTheOldFile() throws {
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        cache.store(["small"], for: root)
        let file = try #require(cache.fileURL(for: root))
        #expect(FileManager.default.fileExists(atPath: file.path))
        cache.store(bulky(65), for: root)
        // The old file would be out of date: it goes; the tree is still in memory.
        #expect(
            !FileManager.default.fileExists(atPath: file.path)
                && !FileManager.default.fileExists(atPath: temporary(of: file))
        )
        #expect(cache.paths(for: root)?.count == 65 * 1_040)
    }

    @Test func aLinkInThePlaceOfTheTemporaryFileIsNotFollowed() throws {
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        cache.store(["old"], for: root)
        let file = try #require(cache.fileURL(for: root))
        let target = box.url("elsewhere")
        try FileManager.default.createSymbolicLink(atPath: temporary(of: file), withDestinationPath: target.path)
        cache.store(["new"], for: root)
        // Nothing is written through the link, and the file keeps what it had.
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(TreeCache.parse(try String(contentsOf: file, encoding: .utf8), root: root) == ["old"])
    }

    @Test func aFileThatCannotBeReplacedIsLeftAndTheTemporaryOneGoes() throws {
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        let file = try #require(cache.fileURL(for: root))
        // A folder with something in it where the file should be: renaming over it fails.
        try FileManager.default.createDirectory(
            at: file.appendingPathComponent("inside"),
            withIntermediateDirectories: true
        )
        cache.store(["a"], for: root)
        #expect(!FileManager.default.fileExists(atPath: temporary(of: file)))
        #expect(FileManager.default.fileExists(atPath: file.appendingPathComponent("inside").path))
    }

    @MainActor @Test func aWriteTheDiskRefusesLeavesTheFileAlone() throws {
        // A kernel makes a write to a closed pipe fail instead of ending the program.
        _ = Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        let file = try #require(cache.fileURL(for: root))
        // Once with the folders too many for the pipe, once with the unread folders.
        for (paths, unscanned) in [(bulky(4), [String]()), (["a"], bulky(4, prefix: "u"))] {
            let fifo = temporary(of: file)
            try? FileManager.default.createDirectory(at: box.url("cache"), withIntermediateDirectories: true)
            #expect(mkfifo(fifo, 0o600) == 0)
            let done = DispatchSemaphore(value: 0)
            OtherThread.start {
                cache.store(paths, unscanned: unscanned, for: root)
                done.signal()
            }
            // The reader goes away without reading: the writer is refused.
            let reader = open(fifo, O_RDONLY)
            close(reader)
            done.wait()
            #expect(!FileManager.default.fileExists(atPath: fifo) && !FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func aPathOfSlashesNotesNothing() throws {
        let cache = TreeCache(directory: nil)
        cache.store(["a"], for: root)
        cache.noteFolder("//", below: root)
        cache.waitForUpdates()
        #expect(cache.paths(for: root) == ["a"])
    }

    @Test func aLongTreeStillKnowsItsFoldersAfterAWrite() throws {
        let cache = TreeCache(directory: nil)
        let paths = (0...100_000).map { "f\($0)" }
        cache.store(paths, for: root)
        cache.noteFolder("new", below: root)
        cache.waitForUpdates()
        // The set of known folders was let go after the write; it is made again, and a folder
        // that is known is not added twice.
        cache.noteFolder("new", below: root)
        cache.noteFolder("f7", below: root)
        cache.waitForUpdates()
        #expect(cache.paths(for: root)?.count == paths.count + 1)
    }
}

/// The scanner on file systems that do not tell the type of an entry, and when cancelled.
@Suite struct CoveragePlacesScanner {
    @Test func entriesOfUnknownTypeAreAskedForTheirType() throws {
        // The descriptor file system lists every entry with an unknown type; a descriptor of a
        // folder is a folder.
        let box = try Sandbox()
        try box.folder("seen")
        try box.folder("hidden")
        #expect(chflags(box.url("hidden").path, UInt32(UF_HIDDEN)) == 0)
        let seen = open(box.url("seen").path, O_RDONLY)
        let hidden = open(box.url("hidden").path, O_RDONLY)
        defer {
            close(seen)
            close(hidden)
        }
        let descriptors = URL(fileURLWithPath: "/dev/fd", isDirectory: true)
        for showHidden in [false, true] {
            let scanner = TreeScanner(root: descriptors, provider: LocalFileSystem(), showHidden: showHidden) { _ in
                true
            }
            var levels: [TreeScanner.Level] = []
            #expect(scanner.run { levels += $0 })
            let names = Set(levels.first?.children ?? [])
            #expect(names.contains("\(seen)") && names.contains("\(hidden)") == showHidden)
            // Standard input and output are no folders.
            #expect(!names.contains("0") || isFolder(descriptor: 0))
            #expect(scanner.subfolders(of: descriptors).contains { $0.name == "\(seen)" })
        }
    }

    func isFolder(descriptor: Int32) -> Bool {
        var info = stat()
        return fstat(descriptor, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    @Test func aCancelledScannerReadsNoFolder() throws {
        let box = try Sandbox()
        try box.folder("a")
        let scanner = TreeScanner(root: box.root, provider: LocalFileSystem())
        scanner.cancellation.cancel()
        #expect(scanner.subfolders(of: box.root).isEmpty)
    }

    @Test func aHiddenFolderIsLeftOutByItsFlag() throws {
        let box = try Sandbox()
        try box.folder("flagged")
        try box.folder("plain")
        #expect(chflags(box.url("flagged").path, UInt32(UF_HIDDEN)) == 0)
        let scanner = TreeScanner(root: box.root, provider: LocalFileSystem())
        #expect(scanner.subfolders(of: box.root).map(\.name) == ["plain"])
        let all = TreeScanner(root: box.root, provider: LocalFileSystem(), showHidden: true)
        #expect(all.subfolders(of: box.root).map(\.name).sorted() == ["flagged", "plain"])
    }

    @Test func aScanStoppedBetweenFoldersOfALevelKeepsWhatItFoundUnread() {
        let memory = MemoryFileSystem()
        memory.addDirectory("/R/a/a1")
        memory.addDirectory("/R/b/b1")
        let scanner = TreeScanner(root: memory.url("/R"), provider: memory, batchSize: 1)
        var received = 0
        #expect(
            !scanner.run { _ in
                received += 1
                if received == 2 { scanner.cancellation.cancel() }
            }
        )
        // The level below "a" was found before the stop and is not read; "b" was not reached.
        #expect(scanner.paths == ["a", "b", "a/a1"] && Set(scanner.unscanned) == ["b", "a/a1"])
    }
}

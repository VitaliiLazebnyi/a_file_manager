import AFMKernel
import Darwin
import Foundation
import TestSupport
import Testing

@testable import PlacesPlugin

/// The tree cache when its files cannot be written as asked: a write that comes late, a tree
/// too big for a file, a temporary file that is in the way, a disk that refuses the data.
@Suite(.serialized)
internal struct CoveragePlacesCacheFiles {
    /// The root whose tree the tests store.
    internal let root = URL(fileURLWithPath: "/Volumes/Disk", isDirectory: true)
    /// A second root, with a file of its own.
    internal let other = URL(fileURLWithPath: "/Volumes/Other", isDirectory: true)

    /// Where the cache writes the file of `root` before it takes the file's place.
    internal func temporary(of file: URL) -> String { file.path + ".tmp\(getpid())" }

    /// Reads everything from `descriptor` until the writer closes it, and closes it.
    internal func drain(_ descriptor: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else {
                break
            }
            data.append(contentsOf: buffer[0..<count])
        }
        close(descriptor)
        return data
    }

    /// Paths that make a file of about `megabytes` megabytes, each starting with `prefix`.
    internal func bulky(_ megabytes: Int, prefix: String) -> [String] {
        let tail = String(repeating: "x", count: 1_000)
        return (0..<(megabytes * 1_040)).map { "\(prefix)\($0)/\(tail)" }
    }

    /// Of two writes that wait behind a slow one, the overtaken first is never made.
    @Test
    internal func aWriteThatWasOvertakenIsNotMade() throws {
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        cache.store(["warm-up"], for: root)
        let blockerFile = try #require(cache.fileURL(for: root))
        let fifo = temporary(of: blockerFile)
        #expect(mkfifo(fifo, 0o600) == 0)
        let group = DispatchGroup()
        // The first write stops in the FIFO, holding the cache's write lock, until it is read.
        let big = bulky(4, prefix: "p")
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
        #expect(Wait.until { cache.entry(for: other)?.paths == ["first"] })
        group.enter()
        OtherThread.start {
            cache.store(["second"], for: other)
            group.leave()
        }
        #expect(Wait.until { cache.entry(for: other)?.paths == ["second"] })
        let written = drain(reader)
        group.wait()
        #expect(written == Data(TreeCache.format(big, root: root).utf8))
        let otherFile = try #require(cache.fileURL(for: other))
        #expect(
            TreeCache.parseEntry(try String(contentsOf: otherFile, encoding: .utf8), root: other)?.paths == ["second"]
        )
    }

    /// A tree too big for a file removes the old file and stays in memory.
    @Test
    internal func aTreeTooBigForAFileRemovesTheOldFile() throws {
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        cache.store(["small"], for: root)
        let file = try #require(cache.fileURL(for: root))
        #expect(FileManager.default.fileExists(atPath: file.path))
        cache.store(bulky(65, prefix: "p"), for: root)
        // The old file would be out of date: it goes; the tree is still in memory.
        #expect(
            !FileManager.default.fileExists(atPath: file.path)
                && !FileManager.default.fileExists(atPath: temporary(of: file))
        )
        #expect(cache.entry(for: root)?.paths.count == 65 * 1_040)
    }

    /// A link where the temporary file goes is not written through.
    @Test
    internal func aLinkInThePlaceOfTheTemporaryFileIsNotFollowed() throws {
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        cache.store(["old"], for: root)
        let file = try #require(cache.fileURL(for: root))
        let target = box.url("elsewhere")
        try FileManager.default.createSymbolicLink(atPath: temporary(of: file), withDestinationPath: target.path)
        cache.store(["new"], for: root)
        // Nothing is written through the link, and the file keeps what it had.
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(TreeCache.parseEntry(try String(contentsOf: file, encoding: .utf8), root: root)?.paths == ["old"])
    }

    /// When the file cannot be replaced it stays as it was, and the temporary file goes.
    @Test
    internal func aFileThatCannotBeReplacedIsLeftAndTheTemporaryOneGoes() throws {
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

    /// A write the disk refuses leaves no file and no temporary file behind.
    @MainActor
    @Test
    internal func aWriteTheDiskRefusesLeavesTheFileAlone() throws {
        // A kernel makes a write to a closed pipe fail instead of ending the program.
        _ = Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        let file = try #require(cache.fileURL(for: root))
        // Once with the folders too many for the pipe, once with the unread folders.
        for (paths, unscanned) in [(bulky(4, prefix: "p"), [String]()), (["a"], bulky(4, prefix: "u"))] {
            let fifo = temporary(of: file)
            try? FileManager.default.createDirectory(at: box.url("cache"), withIntermediateDirectories: true)
            #expect(mkfifo(fifo, 0o600) == 0)
            let done = DispatchSemaphore(value: 0)
            OtherThread.start {
                cache.store(paths, for: root, unscanned: unscanned)
                done.signal()
            }
            // The reader goes away without reading: the writer is refused.
            let reader = open(fifo, O_RDONLY)
            close(reader)
            done.wait()
            #expect(!FileManager.default.fileExists(atPath: fifo) && !FileManager.default.fileExists(atPath: file.path))
        }
    }

    /// A path made only of slashes notes no folder.
    @Test
    internal func aPathOfSlashesNotesNothing() {
        let cache = TreeCache(directory: nil)
        cache.store(["a"], for: root)
        cache.noteFolder("//", below: root)
        cache.waitForUpdates()
        #expect(cache.entry(for: root)?.paths == ["a"])
    }

    /// After a write a long tree makes its set of known folders again, and adds no folder twice.
    @Test
    internal func aLongTreeStillKnowsItsFoldersAfterAWrite() {
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
        #expect(cache.entry(for: root)?.paths.count == paths.count + 1)
    }
}

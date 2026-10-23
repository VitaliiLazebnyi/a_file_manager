import AFMKernel
import Darwin
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import PlacesPlugin

/// The scanner on file systems that do not tell the type of an entry, and when cancelled.
@Suite
internal struct CoveragePlacesScanner {
    /// Entries listed without a type are asked for it, and hidden ones are left out unless shown.
    @Test
    internal func entriesOfUnknownTypeAreAskedForTheirType() throws {
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

    /// Whether the open file `descriptor` is a folder.
    internal func isFolder(descriptor: Int32) -> Bool {
        var info = stat()
        return fstat(descriptor, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// A cancelled scanner reads no folder.
    @Test
    internal func aCancelledScannerReadsNoFolder() throws {
        let box = try Sandbox()
        try box.folder("a")
        let scanner = TreeScanner(root: box.root, provider: LocalFileSystem())
        scanner.cancellation.cancel()
        #expect(scanner.subfolders(of: box.root).isEmpty)
    }

    /// A folder with the hidden flag is left out unless hidden folders are shown.
    @Test
    internal func aHiddenFolderIsLeftOutByItsFlag() throws {
        let box = try Sandbox()
        try box.folder("flagged")
        try box.folder("plain")
        #expect(chflags(box.url("flagged").path, UInt32(UF_HIDDEN)) == 0)
        let scanner = TreeScanner(root: box.root, provider: LocalFileSystem())
        #expect(scanner.subfolders(of: box.root).map(\.name) == ["plain"])
        let all = TreeScanner(root: box.root, provider: LocalFileSystem(), showHidden: true)
        #expect(all.subfolders(of: box.root).map(\.name).sorted() == ["flagged", "plain"])
    }

    /// A scan stopped in the middle of a level keeps the folders it found as unread.
    @Test
    internal func aScanStoppedBetweenFoldersOfALevelKeepsWhatItFoundUnread() {
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

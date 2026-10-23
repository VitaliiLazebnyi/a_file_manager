import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Archives inside archives, and archives on another file system.
@Suite
internal struct ArchivesNestingTests {
    /// The archive file systems in a sandbox of their own.
    internal let bench: ArchiveBench
    /// The sandbox the archives and trees are made in.
    internal var box: Sandbox { bench.box }

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// An archive inside an archive opens like a folder, and a change deep inside is written out to the outer one.
    @Test
    internal func archivesInsideArchives() throws {
        let tree = try bench.makeTree("tree")
        try bench.pack([tree], to: box.url("inner.zip"), innerFolder: "") { $0.format = .zip }
        try bench.pack([tree], to: box.url("inner.tar.gz"), innerFolder: "") { $0.format = .compressedTar(.gzip) }
        let inners = [box.url("inner.zip"), box.url("inner.tar.gz")]
        try bench.pack(inners, to: box.url("outer.zip"), innerFolder: "") { $0.format = .zip }
        let outer = bench.inside(box.url("outer.zip"), "", scheme: ArchiveURL.writableScheme)
        #expect(try bench.names(outer, showHidden: true) == ["inner.tar.gz", "inner.zip"])

        // Enter the inner archives; leaving them leads back into the outer one.
        let innerZip = ArchiveURL.make(scheme: "zip", archive: outer.appending(name: "inner.zip"), innerPath: "")
        let innerTar = ArchiveURL.make(scheme: "archive", archive: outer.appending(name: "inner.tar.gz"), innerPath: "")
        #expect(
            try bench.names(innerZip.appending(name: "tree"), showHidden: true) == [
                "big.log", "empty.txt", "hollow", "readme.txt", "sub"
            ]
        )
        #expect(
            try bench.read(innerTar.appending(name: "tree").appending(name: "big.log"))
                == Data(contentsOf: tree.appendingPathComponent("big.log"))
        )
        #expect(bench.zip.parent(of: innerZip)?.isSameLocation(as: outer) == true)
        #expect(
            bench.fileSystems.displayPath(innerZip.appending(name: "tree")) == box.url("outer.zip").path
                + "/inner.zip/tree"
        )
        #expect(bench.zip.root(of: innerZip.appending(name: "tree")).isSameLocation(as: box.root))

        // A change deep inside travels outwards: the inner archive is rewritten, then the outer.
        try bench.writeText(
            "added inside",
            to: innerZip.appending(name: "tree").appending(name: "added.txt"),
            modified: nil
        )
        try bench.zip.remove(innerZip.appending(name: "tree").appending(name: "big.log"))
        #expect(bench.store.flushAll(cancellation: nil).isEmpty && bench.store.flushAll(cancellation: nil).isEmpty)
        bench.store.close()
        #expect(runTool("/usr/bin/unzip", ["-q", "outer.zip", "-d", "x"], in: box.root).status == 0)
        let listed = runTool("/usr/bin/unzip", ["-Z1", box.url("x/inner.zip").path], in: nil).output
        #expect(listed.contains("tree/added.txt") && !listed.contains("big.log") && listed.contains("tree/readme.txt"))
        #expect(runTool("/usr/bin/unzip", ["-tq", box.url("x/inner.zip").path], in: nil).status == 0)
        #expect(
            try bench.read(innerZip.appending(name: "tree").appending(name: "added.txt")) == Data("added inside".utf8)
        )
    }

    /// A ZIP on another file system is packed, read, changed and added to there, and is read-only where that one is.
    @Test
    internal func anArchiveOnAnotherFileSystem() throws {
        let tree = try bench.makeTree("tree")
        // Packed straight onto the other file system…
        let onServer = bench.memory.url("/store/tree.zip")
        try bench.pack([tree], to: onServer, innerFolder: "") { $0.format = .zip }
        #expect(bench.memory.allPaths == ["/store", "/store/tree.zip"])
        // …opened there, read, changed, and added to.
        let root = ArchiveURL.make(scheme: "zip", archive: onServer, innerPath: "")
        #expect(try bench.names(root.appending(name: "tree"), showHidden: true).count == 5)
        #expect(try bench.read(root.appending(name: "tree").appending(name: "readme.txt")).count == 17_600)
        #expect(bench.fileSystems.displayPath(root.appending(name: "tree")) == "mem:/store/tree.zip/tree")
        try bench.zip.remove(root.appending(name: "tree").appending(name: "big.log"))
        #expect(bench.store.flushAll(cancellation: nil).isEmpty)
        try box.file("more.txt", "more")
        try bench.pack([box.url("more.txt")], to: onServer, innerFolder: "tree/sub") { $0.format = .zip }
        #expect(bench.memory.allPaths == ["/store", "/store/tree.zip"])

        // What lies there now is a sound ZIP with the changes in it.
        let reader = try bench.memory.read(onServer)
        var bytes = Data()
        while let block = try reader.read(upToCount: 1 << 20) { bytes.append(block) }
        try bytes.write(to: box.url("fetched.zip"))
        #expect(runTool("/usr/bin/unzip", ["-tq", box.url("fetched.zip").path], in: nil).status == 0)
        let listed = runTool("/usr/bin/unzip", ["-Z1", box.url("fetched.zip").path], in: nil).output
        #expect(listed.contains("tree/sub/more.txt") && !listed.contains("big.log"))
        // A file system that cannot be written to makes its archives read-only.
        bench.memory.capabilities = []
        #expect(throws: ArchiveError.self) {
            try bench.zip.remove(root.appending(name: "tree").appending(name: "empty.txt"))
        }
        #expect(
            ArchiveFileSystem.scheme(forArchive: onServer, fileSystems: bench.fileSystems, isKnownZip: false)
                == ArchiveURL.readOnlyScheme
        )
    }
}

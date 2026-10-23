import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Archive locations: their URLs, the way out of an archive, the paths shown and typed.
@Suite
internal struct ArchivesFileSystemTests {
    /// The archive file systems in a sandbox of their own.
    internal let bench: ArchiveBench
    /// The sandbox the archives and trees are made in.
    internal var box: Sandbox { bench.box }

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// An archive URL carries the archive and the path inside it, for archives on disk, elsewhere and inside archives.
    @Test
    internal func urlsCarryTheArchiveAndThePathInside() throws {
        let archive = URL(fileURLWithPath: "/Users/me/my photos.zip")
        let root = ArchiveURL.make(scheme: "zip", archive: archive, innerPath: "")
        #expect(
            root.scheme == "zip" && root.path == "/Users/me/my photos.zip" && root.lastPathComponent == "my photos.zip"
        )
        let inner = root.appending(name: "2026").appending(name: "ü #1?.jpg")
        #expect(ArchiveURL.parse(inner) == .inside(ArchiveLocation(archive: archive, innerPath: "2026/ü #1?.jpg")))
        #expect(ArchiveURL.parse(root) == .inside(ArchiveLocation(archive: archive, innerPath: "")))
        #expect(
            ArchiveURL.parse(inner.deletingLastPathComponent())
                == .inside(ArchiveLocation(archive: archive, innerPath: "2026"))
        )
        #expect(inner.isInside(root) && inner.standardized == inner)
        #expect(
            ArchiveURL.make(scheme: "zip", archive: archive, innerPath: "2026/ü #1?.jpg").isSameLocation(as: inner)
        )

        // A path that does not run through the archive is a place on the archive's own file system.
        var components = try #require(URLComponents(url: root, resolvingAgainstBaseURL: false))
        components.path = "/Users/me/Documents/notes.txt"
        let elsewhere = try #require(components.url)
        #expect(ArchiveURL.parse(elsewhere) == .outside(URL(fileURLWithPath: "/Users/me/Documents/notes.txt")))
        #expect(ArchiveURL.resolved(elsewhere).isFileURL && ArchiveURL.resolved(inner) == inner)
        #expect(ArchiveURL.parse(archive) == nil && URL(string: "zip://nonsense/a/b").flatMap(ArchiveURL.parse) == nil)

        // Archives on other file systems, and archives inside archives.
        let remote = try #require(URL(string: "ftp://user@server.example:2121/pub/a%20b/data.tar.gz"))
        let onServer = ArchiveURL.make(scheme: "archive", archive: remote, innerPath: "x/y")
        #expect(ArchiveURL.parse(onServer) == .inside(ArchiveLocation(archive: remote, innerPath: "x/y")))
        let nested = ArchiveURL.make(
            scheme: "zip",
            archive: inner.deletingLastPathComponent().appending(name: "inner.zip"),
            innerPath: "deep/file"
        )
        guard case .inside(let location)? = ArchiveURL.parse(nested) else {
            Issue.record("not inside")
            return
        }
        #expect(
            location.innerPath == "deep/file"
                && location.archive.isSameLocation(as: root.appending(name: "2026").appending(name: "inner.zip"))
        )
        #expect(ArchiveURL.location(of: location.archive)?.archive == archive)
        #expect(nested.path == "/Users/me/my photos.zip/2026/inner.zip/deep/file")
    }

    /// Going up out of an archive leads to the folder that holds it, with the cursor on the archive.
    @MainActor
    @Test
    internal func leavingAnArchiveLeadsToTheFolderThatHoldsIt() throws {
        let archive = try bench.zipOfTree("tree.zip")
        let deep = bench.inside(archive, "tree/sub/deep", scheme: ArchiveURL.writableScheme)
        #expect(bench.zip.parent(of: deep) == bench.inside(archive, "tree/sub", scheme: ArchiveURL.writableScheme))
        #expect(
            bench.zip.parent(of: bench.inside(archive, "tree", scheme: ArchiveURL.writableScheme))
                == bench.inside(archive, "", scheme: ArchiveURL.writableScheme)
        )
        // Above the archive's top folder is the folder on disk, which is not this file system's:
        // there the climb ends.
        let above = try #require(bench.zip.parent(of: bench.inside(archive, "", scheme: ArchiveURL.writableScheme)))
        #expect(above.isFileURL && above.isSameLocation(as: box.root) && bench.zip.parent(of: above) == nil)
        #expect(bench.zip.root(of: deep).isSameLocation(as: box.root))
        #expect(bench.readOnly.parent(of: deep) == nil)

        // The panel loader finds the surroundings the same way, and a member's location leads
        // to its folder with the cursor on it.
        let loaded = try PanelLoader.load(
            bench.inside(archive, "tree/sub/random.bin", scheme: ArchiveURL.writableScheme),
            showHidden: false,
            fileSystems: bench.fileSystems
        )
        #expect(
            loaded.listing.directory == bench.inside(archive, "tree/sub", scheme: ArchiveURL.writableScheme)
                && loaded.focus == "random.bin"
        )
        #expect(loaded.listing.items.map(\.name).sorted() == ["deep", "random.bin"])
        let model = PanelModel(directory: box.root)
        model.show(
            try PanelLoader.load(
                bench.inside(archive, "", scheme: ArchiveURL.writableScheme),
                showHidden: false,
                fileSystems: bench.fileSystems
            )
            .listing
        )
        #expect(
            model.parentTarget?.location.isSameLocation(as: box.root) == true && model.parentTarget?.focus == "tree.zip"
        )
        #expect(model.rootTarget?.focus == "tree.zip")
    }

    /// An archive path is shown and typed like a folder path; formats that cannot change get the read-only file system.
    @Test
    internal func pathsAreShownAndReadLikeFolders() throws {
        let archive = try bench.zipOfTree("tree.zip")
        let inner = bench.inside(archive, "tree/sub", scheme: ArchiveURL.writableScheme)
        let shown = bench.fileSystems.displayPath(inner)
        #expect(shown == archive.path + "/tree/sub")
        // What is shown can be typed back, from anywhere.
        #expect(bench.fileSystems.location(from: shown, relativeTo: bench.memory.url("/")) == inner)
        #expect(
            bench.fileSystems.location(from: archive.path, relativeTo: box.root)
                == bench.inside(archive, "", scheme: ArchiveURL.writableScheme)
        )
        #expect(bench.fileSystems.location(from: archive.path + "/tree/sub/", relativeTo: box.root) == inner)
        #expect(bench.fileSystems.location(from: inner.absoluteString, relativeTo: box.root) == inner)
        // A folder that merely ends like an archive stays a folder, and so does a missing file.
        try box.folder("folder.zip/x")
        #expect(bench.fileSystems.location(from: box.url("folder.zip/x").path, relativeTo: box.root).isFileURL)
        #expect(bench.fileSystems.location(from: box.url("missing.zip").path, relativeTo: box.root).isFileURL)
        // Formats that cannot be changed get the read-only file system.
        try bench.pack([box.url("tree")], to: box.url("tree.tgz"), innerFolder: "") { options in
            options.format = .compressedTar(.gzip)
        }
        let readOnly = bench.fileSystems.location(from: box.url("tree.tgz").path + "/tree", relativeTo: box.root)
        #expect(try readOnly.scheme == ArchiveURL.readOnlyScheme && bench.names(readOnly, showHidden: true).count == 5)
        #expect(bench.zip.capabilities == [.write, .deferredWrites] && bench.readOnly.capabilities.isEmpty)

        // A plain path typed while inside an archive means the disk.
        let typed = bench.fileSystems.location(from: box.url("tree/readme.txt").path, relativeTo: inner)
        #expect(typed.isFileURL && typed.path == box.url("tree/readme.txt").path)
        #expect(bench.zip.volume(of: inner)?.name == "tree.zip")
    }
}

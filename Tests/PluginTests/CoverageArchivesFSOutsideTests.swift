import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The archive file systems asked about places that do not run through an archive (the user
/// typed a plain path while a panel was inside one), about URLs they did not write, and
/// without the program's file systems.
@Suite
internal struct CoverageArchivesFSOutsideTests {
    private let bench: ArchiveBench
    private var box: Sandbox { bench.box }
    private var zip: ArchiveFileSystem { bench.zip }

    /// A ZIP of a small tree in a sandbox, with the archive file systems over the local disk
    /// and a memory file system.
    internal init() throws {
        bench = try ArchiveBench()
        try box.file("tree/readme.txt", "read me")
        try box.file("tree/sub/inner.txt", "inner")
        #expect(runTool("/usr/bin/zip", ["-qr", "tree.zip", "tree"], in: box.root).status == 0)
    }

    /// A place on the file system of `archive` that does not run through it.
    private static func outside(_ archive: URL, _ path: String) throws -> URL {
        let root = ArchiveURL.make(scheme: ArchiveURL.writableScheme, archive: archive)
        var components = try #require(URLComponents(url: root, resolvingAgainstBaseURL: false))
        components.path = path
        return try #require(components.url)
    }

    private func outside(_ path: String) throws -> URL {
        try Self.outside(box.url("tree.zip"), box.url(path).path)
    }

    private func inside(_ path: String = "") -> URL {
        bench.inside(box.url("tree.zip"), path)
    }

    private func text(_ path: String) -> String? {
        box.read(path)
    }

    /// Folders and files outside the archive are made, written, read, listed, changed, moved,
    /// copied and removed by the file system they lie on, with a cancellation and without.
    @Test
    internal func aPlaceOutsideIsChangedByItsOwnFileSystem() throws {
        let flag = CancellationFlag()
        try zip.createDirectory(at: outside("made"))
        try zip.createDirectory(at: outside("made2"), cancellation: flag)
        for (name, writer) in [
            ("made/one.txt", try zip.write(outside("made/one.txt"))),
            ("made/two.txt", try zip.write(outside("made/two.txt"), cancellation: flag))
        ] {
            try writer.write(Data(name.utf8))
            try writer.close(attributes: FileAttributes())
        }
        #expect(text("made/one.txt") == "made/one.txt" && text("made/two.txt") == "made/two.txt")
        #expect(zip.item(at: try outside("made/one.txt"))?.size == 12)
        let reader = try zip.read(outside("made/one.txt"))
        #expect(try reader.read(upToCount: 100) == Data("made/one.txt".utf8))
        reader.close()
        var received: [String] = []
        try zip.list(outside("made"), showHidden: false) { items in
            received += items.map(\.name)
            return true
        }
        #expect(received.sorted() == ["one.txt", "two.txt"])

        try zip.setAttributes(FileAttributes(permissions: 0o600), of: outside("made/one.txt"))
        try zip.setAttributes(FileAttributes(permissions: 0o640), of: outside("made/two.txt"), cancellation: flag)
        let permissions = try ["one.txt", "two.txt"]
            .map { name in
                try FileManager.default.attributesOfItem(atPath: box.url("made/\(name)").path)[.posixPermissions]
                    as? Int
            }
        #expect(permissions == [0o600, 0o640])

        try zip.move(outside("made/one.txt"), to: outside("made2/one.txt"), replacing: false)
        try zip.move(outside("made/two.txt"), to: outside("made2/two.txt"), replacing: false, cancellation: flag)
        try zip.copy(outside("made2/one.txt"), to: outside("made/copy1.txt")) { _ in true }
        try zip.copy(outside("made2/two.txt"), to: outside("made/copy2.txt"), cancellation: flag) { _ in true }
        #expect(text("made/copy1.txt") == "made/one.txt" && text("made/copy2.txt") == "made/two.txt")
        try zip.remove(outside("made/copy1.txt"))
        try zip.remove(outside("made/copy2.txt"), cancellation: flag)
        #expect(!box.exists("made/copy1.txt") && !box.exists("made/copy2.txt") && box.exists("made2/one.txt"))

        try zip.setQuarantine(Data("0081;quarantined".utf8), of: outside("made2/one.txt"), cancellation: flag)
        #expect(zip.quarantine(of: try outside("made2/one.txt")) == Data("0081;quarantined".utf8))
        #expect(zip.displayPath(try outside("made2")) == box.url("made2").path)
        let made = try outside("made2")
        #expect(zip.volume(of: made) != nil && zip.volume(of: made, cancellation: flag) != nil)
        // The top of the disk has no parent: going up ends there.
        let top = try Self.outside(box.url("tree.zip"), "/")
        #expect(zip.root(of: top) == top)
    }

    /// Places on two different file systems, or in an archive and outside it, are not moved
    /// or copied by this file system; neither are members of an archive that cannot be changed.
    @Test
    internal func placesOnDifferentFileSystemsCrossVolumes() throws {
        let onDisk = try outside("tree")
        let inMemory = try Self.outside(bench.memory.url("/store/a.zip"), "/store/b.txt")
        let flag = CancellationFlag()
        #expect(throws: FileSystemError.self) { try zip.move(onDisk, to: inMemory, replacing: false) }
        #expect(throws: FileSystemError.self) { try zip.copy(onDisk, to: inMemory) { _ in true } }
        #expect(throws: FileSystemError.self) { try zip.copy(onDisk, to: inMemory, cancellation: flag) { _ in true } }
        #expect(throws: FileSystemError.self) {
            try zip.copy(inside("tree/readme.txt"), to: onDisk, cancellation: flag) { _ in true }
        }
        try bench.pack([box.url("tree")], to: box.url("tree.tgz")) { $0.format = .compressedTar(.gzip) }
        let packed = bench.inside(box.url("tree.tgz"), "tree/readme.txt", scheme: ArchiveURL.readOnlyScheme)
        let copy = bench.inside(box.url("tree.tgz"), "tree/copy.txt", scheme: ArchiveURL.readOnlyScheme)
        #expect(throws: FileSystemError.self) {
            try bench.readOnly.copy(packed, to: copy, cancellation: flag) { _ in true }
        }
    }

    /// A copy inside a ZIP with a cancellation duplicates the member and tells its size.
    @Test
    internal func aCopyInsideAZIPWithACancellationDuplicatesTheMember() throws {
        var told: [Int64] = []
        let (member, copy) = (inside("tree/readme.txt"), inside("tree/again.txt"))
        try zip.copy(member, to: copy, cancellation: CancellationFlag()) { size in
            told.append(size)
            return true
        }
        let again = try bench.read(inside("tree/again.txt"))
        #expect(told == [7] && again == Data("read me".utf8))
    }

    /// URLs of the scheme that this code did not write have no capabilities, no mark, no
    /// volume, nothing to commit, and are shown as they are.
    @Test
    internal func urlsThisCodeDidNotWriteHaveNothing() throws {
        let nonsense = try #require(URL(string: "zip://nonsense/a/b"))
        #expect(zip.capabilities(for: nonsense).isEmpty && zip.quarantine(of: nonsense) == nil)
        #expect(zip.volume(of: nonsense) == nil && zip.volume(of: nonsense, cancellation: CancellationFlag()) == nil)
        try zip.commit(nonsense, cancellation: CancellationFlag())
        #expect(zip.displayPath(nonsense) == "zip://nonsense/a/b")
        // A place outside an archive on a file system nobody provides.
        let unknown = try Self.outside(try #require(URL(string: "nosuch://host/a.zip")), "/x")
        #expect(zip.capabilities(for: unknown).isEmpty && zip.volume(of: unknown) == nil)
    }

    /// Without the program's file systems, places outside an archive cannot be reached and
    /// archives elsewhere cannot be fetched; paths are shown as the archive's own.
    @Test
    internal func withoutFileSystemsOnlyTheDiskIsKnown() throws {
        let alone = ArchiveStore(environment: ArchiveEnvironment())
        defer { alone.close() }
        let provider = ArchiveFileSystem(scheme: ArchiveURL.writableScheme, store: alone)
        #expect(provider.displayPath(inside("tree")) == box.url("tree.zip").path + "/tree")
        #expect(provider.displayPath(try outside("made")) == box.url("made").path)
        #expect(throws: FileSystemError.self) { try provider.createDirectory(at: try outside("made")) }
        #expect(throws: FileSystemError.self) { _ = try alone.archive(at: bench.memory.url("/a.zip")) }
        let scheme = ArchiveFileSystem.scheme(forArchive: box.url("tree.zip"), fileSystems: nil)
        #expect(scheme == ArchiveURL.readOnlyScheme)
    }

    /// A folder that is named like an archive is a folder: what lies below it is listed.
    @Test
    internal func aFolderNamedLikeAnArchiveIsAFolder() throws {
        try box.file("folder.zip/sub/x.txt", "x")
        let place = bench.inside(box.url("folder.zip"), "sub")
        #expect(try zip.list(place, showHidden: false).map(\.name) == ["x.txt"])
    }

    /// A folder inside an archive is listed in one piece; a member is not written once the
    /// cancellation is set.
    @Test
    internal func listingInOnePieceAndWritingAfterACancellation() throws {
        var pieces: [[String]] = []
        try zip.list(inside("tree"), showHidden: false) { items in
            pieces.append(items.map(\.name).sorted())
            return true
        }
        #expect(pieces == [["readme.txt", "sub"]])
        let flag = CancellationFlag()
        flag.cancel()
        let error = #expect(throws: ArchiveError.self) {
            _ = try zip.write(inside("tree/late.txt"), cancellation: flag)
        }
        #expect(error?.errorDescription == ArchiveError.cancelled.errorDescription)
    }

    /// A folder that is not in the archive is not found, and neither is a member; a folder
    /// cannot be read as a file.
    @Test
    internal func missingPlacesAndFoldersInsideAnArchive() throws {
        #expect(throws: ArchiveError.self) { _ = try zip.list(inside("tree/missing"), showHidden: false) }
        #expect(throws: ArchiveError.self) { _ = try zip.read(inside("tree/missing.txt")) }
        #expect(throws: FileSystemError.self) { _ = try zip.read(inside("tree/sub")) }
    }

    /// One location keeps its place; a path from the home folder is read from there.
    @Test
    internal func singleLocationsAndHomePaths() {
        let one = [inside("tree/readme.txt")]
        #expect(zip.readOrder(of: one) == one)
        #expect(zip.location(from: "~/afm-no-such-folder/a.zip/x") == nil)
    }

    /// On a volume that is not asked (a server), a path that goes on behind a name like an
    /// archive's runs through the archive; one that ends with the name is the file itself.
    @Test
    internal func onAServerThePathTextDecides() {
        let provider = ArchiveFileSystem(scheme: ArchiveURL.readOnlyScheme, store: bench.store) { _ in .unasked }
        let through = provider.location(from: "/Volumes/server/a.tgz/inner")
        #expect(
            through.flatMap(ArchiveURL.location(of:))
                == ArchiveLocation(archive: URL(fileURLWithPath: "/Volumes/server/a.tgz"), innerPath: "inner")
        )
        #expect(provider.location(from: "/Volumes/server/a.tgz") == nil)
    }
}

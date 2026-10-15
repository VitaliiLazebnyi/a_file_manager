import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Packing into a ZIP on the local disk a file under the name of a folder of the archive, and
/// the other way round: the archive stays as it was and the answer is the one an archive on a
/// server gives (`CovNetArchiveOnServer`).
@Suite
internal struct ArcFixPackKindsTests {
    private let bench: ArchiveBench
    private var box: Sandbox { bench.box }

    /// A bench of its own for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// Packs `source` into `archive` and returns the error, if any.
    private func failure(packing source: URL, into archive: URL) throws -> (any Error)? {
        let options = PackOptions()
        let packer = Packer(
            fileSystems: bench.fileSystems,
            store: bench.store,
            monitor: bench.monitor,
            options: options
        )
        return packer.run([try bench.item(source)], archive: archive).failure
    }

    /// An archive with the folder `x` and `x/inside.txt` in it, packed from the disk.
    private func archiveWithAFolder() throws -> URL {
        let archive = box.url("folder.zip")
        try bench.pack([try box.folder("x")], to: archive)
        try box.file("x/inside.txt", "inside")
        try bench.pack([box.url("x")], to: archive)
        try FileManager.default.removeItem(at: box.url("x"))
        return archive
    }

    /// A file packed under the name of a folder that holds a file leaves the folder and its
    /// file, and fails as on a server.
    @Test
    internal func aFileDoesNotTakeThePlaceOfAFolderWithContents() throws {
        let archive = try archiveWithAFolder()
        let before = CoverageArchives.listed(archive).sorted()
        #expect(before == ["x/", "x/inside.txt"])
        let failure = try failure(packing: try box.file("x", "a file now"), into: archive)
        #expect(failure?.localizedDescription == FileSystemError.alreadyExists("x").errorDescription)
        #expect(CoverageArchives.listed(archive).sorted() == before)
        #expect(CoverageArchives.contents(of: "x/inside.txt", in: archive) == "inside")
    }

    /// A file packed under the name of an empty folder leaves the folder, as on a server.
    @Test
    internal func aFileDoesNotTakeThePlaceOfAnEmptyFolder() throws {
        let archive = box.url("empty.zip")
        try bench.pack([try box.folder("x")], to: archive)
        try FileManager.default.removeItem(at: box.url("x"))
        let failure = try failure(packing: try box.file("x", "a file now"), into: archive)
        #expect(failure?.localizedDescription == FileSystemError.alreadyExists("x").errorDescription)
        #expect(CoverageArchives.listed(archive) == ["x/"])
    }

    /// A folder that has no record of its own, only members inside it, is a folder all the same.
    @Test
    internal func aFolderOnlyItsMembersNameIsAFolderToo() throws {
        let archive = try CoverageArchives.zip("unlisted.zip", in: box, ["x/deep/inside.txt": "inside"], options: [])
        #expect(CoverageArchives.listed(archive) == ["x/deep/inside.txt"])
        let failure = try failure(packing: try box.file("x", "a file now"), into: archive)
        #expect(failure?.localizedDescription == FileSystemError.alreadyExists("x").errorDescription)
        #expect(CoverageArchives.listed(archive) == ["x/deep/inside.txt"])
    }

    /// A folder packed under the name of a file of the archive leaves the file there.
    @Test
    internal func aFolderDoesNotTakeThePlaceOfAFile() throws {
        let archive = box.url("file.zip")
        try bench.pack([try box.file("x", "a file")], to: archive)
        try FileManager.default.removeItem(at: box.url("x"))
        try box.file("x/inside.txt", "inside")
        let failure = try failure(packing: box.url("x"), into: archive)
        #expect(failure?.localizedDescription == ArchiveError.notADirectory("x").errorDescription)
        #expect(CoverageArchives.listed(archive) == ["x"])
        #expect(CoverageArchives.contents(of: "x", in: archive) == "a file")
    }

    /// A folder packed again joins the one there, and a file packed again takes the place of
    /// the one before, also below a folder chosen in the archive.
    @Test
    internal func membersOfTheirOwnKindArePackedAgain() throws {
        let archive = try archiveWithAFolder()
        try box.file("x/inside.txt", "again")
        try box.file("x/new.txt", "new")
        #expect(try failure(packing: box.url("x"), into: archive) == nil)
        #expect(CoverageArchives.listed(archive).sorted() == ["x/", "x/inside.txt", "x/new.txt"])
        #expect(CoverageArchives.contents(of: "x/inside.txt", in: archive) == "again")
        try bench.pack([try box.file("inside.txt", "below")], to: archive, innerFolder: "x")
        #expect(CoverageArchives.contents(of: "x/inside.txt", in: archive) == "below")
        #expect(CoverageArchives.isSound(archive))
    }
}

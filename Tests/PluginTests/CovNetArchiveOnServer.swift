import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Packing into an archive on a server (played by a memory file system): a file under the name of a folder, and the
/// other way round.
@Suite
internal struct CovNetArchiveOnServer {
    private let bench: ArchiveBench
    private let archive: URL

    /// A bench with an archive on the memory file system.
    internal init() throws {
        bench = try ArchiveBench()
        archive = bench.memory.url("server.zip")
    }

    /// Packs `source` into the archive.
    private func pack(_ source: URL) throws -> PackResult {
        let packer = Packer(
            fileSystems: bench.fileSystems,
            store: bench.store,
            monitor: bench.monitor,
            options: PackOptions()
        )
        return packer.run([try bench.item(source)], archive: archive, innerFolder: "")
    }

    /// What is at the top of the archive.
    private func top() throws -> [FileItem] {
        try bench.fileSystems.provider(for: bench.inside(archive)).list(bench.inside(archive), showHidden: true)
    }

    /// A file packed under the name of an empty folder of the archive leaves the folder there, and says why.
    @Test
    internal func aFileDoesNotTakeThePlaceOfAnEmptyFolder() throws {
        #expect(try pack(try bench.box.folder("x")).failure == nil)
        try FileManager.default.removeItem(at: bench.box.url("x"))
        let result = try pack(try bench.box.file("x", "a file now"))
        #expect(result.failure?.localizedDescription == FileSystemError.alreadyExists("x").errorDescription)
        let entries = try top()
        #expect(entries.map(\.name) == ["x"] && entries.first?.isDirectory == true)
    }

    /// A folder packed under the name of a file of the archive leaves the file there, and says why.
    @Test
    internal func aFolderDoesNotTakeThePlaceOfAFile() throws {
        #expect(try pack(try bench.box.file("x", "a file")).failure == nil)
        try FileManager.default.removeItem(at: bench.box.url("x"))
        #expect(try pack(try bench.box.folder("x")).failure != nil)
        let entries = try top()
        #expect(entries.map(\.name) == ["x"] && entries.first?.isDirectory == false)
        #expect(String(bytes: try bench.read(bench.inside(archive, "x")), encoding: .utf8) == "a file")
    }

    /// A folder of the archive moved onto a file of it leaves the file there.
    @Test
    internal func aFolderMovedOntoAFileLeavesTheFile() throws {
        try bench.box.file("x", "a file")
        try bench.box.folder("folder")
        #expect(try pack(bench.box.url("x")).failure == nil)
        #expect(try pack(bench.box.url("folder")).failure == nil)
        let archived = try bench.fileSystems.provider(for: bench.inside(archive))
        #expect(throws: FileSystemError.self) {
            try archived.move(bench.inside(archive, "folder"), to: bench.inside(archive, "x"), replacing: true)
        }
        #expect(try top().map(\.name).sorted() == ["folder", "x"])
    }

    /// A file packed again takes the place of the one before.
    @Test
    internal func aFilePackedAgainTakesThePlaceOfTheOneBefore() throws {
        #expect(try pack(try bench.box.file("x", "before")).failure == nil)
        #expect(try pack(try bench.box.file("x", "after")).failure == nil)
        #expect(String(bytes: try bench.read(bench.inside(archive, "x")), encoding: .utf8) == "after")
    }
}

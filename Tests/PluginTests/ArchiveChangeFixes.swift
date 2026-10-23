import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Changes of ZIPs that cannot simply be appended to, packing into an existing archive, and large members written
/// through the file system.
@Suite
internal struct ArchiveChangeFixes: ArchiveFixSuite {
    /// The archive file systems and the sandbox of the test.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// An archive that lists a name twice is not changed; an entry without a usable name is not shown and stays.
    @Test
    internal func anArchiveThatListsANameTwiceIsNotChanged() throws {
        let archive = try writeZip("twice.zip") { writer in
            for _ in 0..<2 {
                try writer.copyMember(member("same.txt", isDirectory: false), check: nil)
            }
            try writer.copyMember(member("/", isDirectory: true), check: nil)
            try writer.copyMember(member("other.txt", isDirectory: false), check: nil)
        }
        #expect(try bench.names(bench.inside(archive)) == ["other.txt", "same.txt"])
        #expect(throws: ArchiveError.self) { try bench.zip.remove(bench.inside(archive, "other.txt")) }
        #expect(throws: ArchiveError.self) { _ = try bench.zip.write(bench.inside(archive, "new.txt")) }
        #expect(listed(archive).count == 4)
        // An entry without a usable name is not shown, and stays when the archive is changed.
        let odd = try writeZip("odd.zip") { writer in
            try writer.copyMember(member("/", isDirectory: true), check: nil)
            try writer.copyMember(member("other.txt", isDirectory: false), check: nil)
        }
        for clones in [true, false] {
            bench.environment.clonesArchives = clones
            try write("x", to: bench.inside(odd, "new\(clones).txt"))
            try bench.store.flush(odd, cancellation: nil)
            #expect(listed(odd).contains("/") && listed(odd).contains("new\(clones).txt"))
        }
    }

    /// A new member record named `name`, dated now: a file (rw-r--r--) or a folder (rwxr-xr-x).
    private func member(_ name: String, isDirectory: Bool) -> ZipRecord {
        .new(
            name: name,
            isDirectory: isDirectory,
            modified: Date(),
            permissions: isDirectory ? 0o755 : 0o644,
            isSymbolicLink: false
        )
    }

    /// Packing into an existing archive appends and tests only what is new; replacing a member writes the archive anew.
    @Test
    internal func packingIntoAnExistingArchiveAddsToItAndTestsOnlyWhatIsNew() throws {
        let archive = try makeZip()
        let original = try Data(contentsOf: archive)
        let directory = try ZipDirectory.read(RandomAccessFile(archive, shownAs: nil), maxEntries: .max, check: nil)
            .directoryOffset
        // An old member is damaged where its data lies; the test after packing does not read it.
        var damaged = original
        let file = try RandomAccessFile(archive, shownAs: nil)
        let random = try #require(
            ZipDirectory.read(file, maxEntries: .max, check: nil).records.first { $0.name == "tree/sub/random.bin" }
        )
        guard case .archive(let offset, _) = random.source else {
            return
        }
        damaged[Int(try ZipDirectory.localHeader(of: random, at: offset, in: file).dataOffset) + 1_000] ^= 0xFF
        try damaged.write(to: archive)
        try box.file("extra/one.txt", "one")
        try box.file("extra/two.txt", String(repeating: "two", count: 500_000))
        try bench.pack([box.url("extra")], to: archive, innerFolder: "tree") { $0.verifies = true }
        let now = try Data(contentsOf: archive)
        #expect(now.prefix(Int(directory)) == damaged.prefix(Int(directory)))
        #expect(Set(listed(archive)).isSuperset(of: ["tree/extra/one.txt", "tree/extra/two.txt", "tree/readme.txt"]))
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/extra/two.txt"]).output.count == 1_500_000)
        // The whole test still finds the damage.
        #expect(
            try
                !ArchiveTester.test(
                    bench.store.archive(at: archive, cancellation: nil),
                    cancellation: CancellationFlag(),
                    counter: nil,
                    members: .all
                )
                .isEmpty
        )
        // Replacing a member writes the archive anew.
        try original.write(to: archive)
        try box.file("tree/readme.txt", "shorter")
        try bench.pack([box.url("tree/readme.txt")], to: archive, innerFolder: "tree") { $0.verifies = true }
        #expect(
            isSound(archive) && runTool("/usr/bin/unzip", ["-p", archive.path, "tree/readme.txt"]).output == "shorter"
        )
        #expect(listed(archive).filter { $0 == "tree/readme.txt" }.count == 1)
    }

    /// A large member written through the file system is compressed in pieces, the last of which may be empty.
    @Test
    internal func aMemberWrittenThroughTheFileSystemIsCompressedInPieces() throws {
        let archive = try makeZip()
        // Larger than one window of pieces on any machine, with a tail that is no whole piece.
        var data = Data()
        var line = 0
        while data.count < (ProcessInfo.processInfo.activeProcessorCount + 3) * (1 << 20) + 12_345 {
            data.append(Data("line \(line) of a long file that is written through the file system\n".utf8))
            line += 1
        }
        let member = bench.inside(archive, "tree/long.txt")
        let writer = try bench.zip.write(member)
        var offset = 0
        while offset < data.count {
            let end = min(offset + 300_000, data.count)
            try writer.write(data.subdata(in: offset..<end))
            offset = end
        }
        try writer.close(attributes: FileAttributes())
        #expect(try bench.read(member) == data)
        try bench.store.flush(archive, cancellation: nil)
        #expect(isSound(archive))
        try box.folder("long")
        #expect(
            runTool("/usr/bin/unzip", ["-q", archive.path, "tree/long.txt", "-d", box.url("long").path]).status == 0
        )
        #expect(try Data(contentsOf: box.url("long/tree/long.txt")) == data)
        let entry = try #require(try bench.store.archive(at: archive, cancellation: nil).entry("tree/long.txt"))
        #expect(entry.size == Int64(data.count) && entry.packedSize < entry.size / 3)
        // A size that is exactly a number of windows ends in an empty last piece.
        let exact = bench.inside(archive, "tree/exact.bin")
        let window = Data(repeating: 65, count: max(2, ProcessInfo.processInfo.activeProcessorCount) << 20)
        let second = try bench.zip.write(exact)
        try second.write(window)
        try second.close(attributes: FileAttributes())
        try bench.store.flush(archive, cancellation: nil)
        #expect(try isSound(archive) && bench.read(exact) == window)
    }
}

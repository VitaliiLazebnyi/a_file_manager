import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Unpack into folders of the local disk: what is chosen, what collides, and Cancel.
@Suite
internal struct CoverageArchivesFormatsUnpack {
    private let bench: ArchiveBench
    private var box: Sandbox { bench.box }

    /// A new bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// An archive of `files` (path and text), packed from a folder of the sandbox.
    private func archive(_ files: [String: String], format: ArchiveFormat = .zip) throws -> URL {
        let name = "source-\(UUID().uuidString)"
        for (path, text) in files {
            try box.file("\(name)/\(path)", text)
        }
        let archive = box.url("\(name).\(format.defaultExtension)")
        var options = PackOptions()
        options.format = format
        options.separateArchives = true
        options.skipsBaseFolder = true
        let packer = Packer(
            fileSystems: bench.fileSystems,
            store: bench.store,
            monitor: bench.monitor,
            options: options
        )
        let result = packer.run([try bench.item(box.url(name))], archive: archive)
        #expect(result.failure == nil)
        return archive
    }

    private func unpack(
        _ archive: URL,
        into target: URL,
        source: (Unpacker.Source) -> Unpacker.Source = { $0 },
        monitor: (any JobMonitor)? = nil,
        options: UnpackOptions = UnpackOptions(),
        whileUnpacking: (@Sendable (ArchiveEntry) -> Void)? = nil,
        answers: [UnpackConflictChoice] = []
    ) throws -> (result: UnpackResult, asked: Int) {
        var left = answers
        var asked = 0
        let unpacker = Unpacker(
            fileSystems: bench.fileSystems,
            monitor: monitor ?? bench.monitor,
            options: options,
            whileUnpacking: whileUnpacking
        ) { _, _ in
            asked += 1
            return left.isEmpty ? .overwrite : left.removeFirst()
        }
        let result = unpacker.run(
            [source(Unpacker.Source(archive: try bench.store.archive(at: archive)))],
            into: target
        )
        return (result, asked)
    }

    /// A selected path the archive does not hold brings nothing.
    @Test
    internal func aSelectionOfNothingBringsNothing() throws {
        let archive = try archive(["a.txt": "a"])
        let target = try box.folder("target")
        let outcome = try unpack(
            archive,
            into: target,
            source: { source in
                var chosen = source
                chosen.selection = ["missing.txt"]
                return chosen
            }
        )
        #expect(outcome.result.unpacked == 0 && outcome.result.problems.isEmpty)
    }

    /// Without paths, the second of two files of the same name is passed over.
    @Test
    internal func withoutPathsTheSecondFileOfANameIsPassedOver() throws {
        let archive = try archive(["a/same.txt": "first", "b/same.txt": "second"])
        let target = try box.folder("target")
        var options = UnpackOptions()
        options.keepsPaths = false
        let outcome = try unpack(archive, into: target, options: options)
        #expect(outcome.result.unpacked == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["same.txt"])
    }

    /// A folder that stands where a file is to go is reported, and stays.
    @Test
    internal func aFolderWhereAFileIsToGoIsReported() throws {
        let archive = try archive(["x.txt": "x"])
        let target = try box.folder("target")
        try box.folder("target/x.txt")
        let outcome = try unpack(archive, into: target)
        #expect(outcome.result.problems == ["x.txt: a folder with this name exists"])
    }

    /// The answers to collisions: skip one, then overwrite all without asking again.
    @Test
    internal func skipOneThenOverwriteAll() throws {
        let archive = try archive(["a.txt": "new", "b.txt": "new", "c.txt": "new"])
        let target = try box.folder("target")
        for name in ["a.txt", "b.txt", "c.txt"] {
            try box.file("target/\(name)", "old")
        }
        let outcome = try unpack(archive, into: target, answers: [.skip, .overwriteAll])
        #expect(outcome.asked == 2)
        let texts = ["a.txt", "b.txt", "c.txt"].map { box.read("target/\($0)") }
        #expect(texts.sorted { ($0 ?? "") < ($1 ?? "") } == ["new", "new", "old"])
    }

    /// Cancel as the answer to a collision ends the unpacking before anything is written.
    @Test
    internal func cancelAsTheAnswerEndsTheUnpacking() throws {
        let archive = try archive(["a.txt": "new"])
        let target = try box.folder("target")
        try box.file("target/a.txt", "old")
        let outcome = try unpack(archive, into: target, answers: [.cancel])
        #expect(outcome.result.cancelled && box.read("target/a.txt") == "old")
    }

    /// A job cancelled before it starts unpacks nothing.
    @Test
    internal func aJobCancelledBeforeItStartsUnpacksNothing() throws {
        let archive = try archive(["a.txt": "a"])
        let target = try box.folder("target")
        let monitor = CoverageArchivesFormatsMonitor()
        monitor.cancellation.cancel()
        let outcome = try unpack(archive, into: target, monitor: monitor)
        #expect(outcome.result.cancelled && outcome.result.unpacked == 0)
    }

    /// Cancel while a member is written stops it, and the links that would come after it.
    @Test
    internal func cancelWhileAMemberIsWrittenStopsTheRest() throws {
        let source = try box.folder("linked")
        try Data(count: 3 << 20).write(to: source.appending(name: "big.bin"))
        try FileManager.default.createSymbolicLink(
            atPath: source.appending(name: "link").path,
            withDestinationPath: "big.bin"
        )
        let archive = box.url("linked.zip")
        try bench.pack([source], to: archive)
        let target = try box.folder("target")
        let monitor = CoverageArchivesFormatsMonitor()
        let outcome = try unpack(
            archive,
            into: target,
            monitor: monitor,
            whileUnpacking: { _ in monitor.cancellation.cancel() }
        )
        #expect(outcome.result.cancelled && outcome.result.unpacked == 1 && outcome.result.problems.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.appending(name: "linked").path).isEmpty)
    }

    /// In an archive that is read in one pass, Cancel while a member is written ends the pass.
    @Test
    internal func cancelInOnePassEndsThePass() throws {
        let archive = try archive(["a.txt": String(repeating: "a", count: 3 << 20)], format: .compressedTar(.gzip))
        bench.environment.hasRoom = { _, _ in false }
        let target = try box.folder("target")
        let monitor = CoverageArchivesFormatsMonitor()
        let outcome = try unpack(
            archive,
            into: target,
            monitor: monitor,
            whileUnpacking: { _ in monitor.cancellation.cancel() }
        )
        #expect(outcome.result.cancelled && outcome.result.unpacked == 0)
    }

    /// In an archive that is read in one pass, a member the disk refuses is reported and the
    /// pass goes on.
    @Test
    internal func aMemberRefusedInOnePassIsReported() throws {
        let archive = try archive(["a.txt": "a", "b.txt": "b"], format: .compressedTar(.gzip))
        bench.environment.hasRoom = { _, _ in false }
        let target = try box.folder("target")
        defer { chmod(target.path, 0o755) }
        let outcome = try unpack(
            archive,
            into: target,
            whileUnpacking: { entry in chmod(target.path, entry.name == "a.txt" ? 0o555 : 0o755) }
        )
        let refused = "\(String(cString: strerror(EACCES))): \(target.path)/a.txt"
        #expect(outcome.result.problems == ["a.txt: \(refused)"])
        #expect(outcome.result.unpacked == 1 && box.read("target/b.txt") == "b")
    }
}

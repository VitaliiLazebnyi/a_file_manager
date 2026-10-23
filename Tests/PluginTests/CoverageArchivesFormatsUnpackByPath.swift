import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Unpack by path, through the target's file system: into a folder that is not on a disk of
/// this machine (a network volume, taken for one here) and onto a server.
@Suite
internal struct CoverageArchivesFormatsUnpackByPath {
    private let bench: ArchiveBench
    private var box: Sandbox { bench.box }

    /// A new bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// A ZIP of the folder `name` of the sandbox, which `make` fills first.
    private func archive(_ name: String, _ make: (URL) throws -> Void) throws -> URL {
        let folder = try box.folder(name)
        try make(folder)
        let archive = box.url("\(name).zip")
        try bench.pack([folder], to: archive)
        return archive
    }

    /// Unpacks `archive` into `target`, taking every folder for one on another machine.
    private func unpack(
        _ archive: URL,
        into target: URL,
        monitor: (any JobMonitor)? = nil,
        whenAsked: @escaping () -> Void = {
            // Nothing to note.
        }
    ) throws -> UnpackResult {
        let unpacker = Unpacker(
            fileSystems: bench.fileSystems,
            monitor: monitor ?? bench.monitor,
            options: UnpackOptions(),
            whileUnpacking: nil
        ) { _, _ in
            whenAsked()
            return .overwrite
        }
        unpacker.isOnLocalVolume = { _ in false }
        return unpacker.run(
            [Unpacker.Source(archive: try bench.store.archive(at: archive, cancellation: nil))],
            into: target
        )
    }

    /// Files, rights and links arrive by path as they do through an open folder.
    @Test
    internal func filesRightsAndLinksArriveByPath() throws {
        let archive = try archive("tree") { folder in
            let script = folder.appending(name: "run.sh")
            try Data("echo\n".utf8).write(to: script)
            chmod(script.path, 0o777)
            try FileManager.default.createSymbolicLink(
                atPath: folder.appending(name: "link").path,
                withDestinationPath: "run.sh"
            )
        }
        let target = box.url("target")
        let result = try unpack(archive, into: target)
        #expect(result.problems.isEmpty && result.unpacked == 3)
        #expect(box.read("target/tree/run.sh") == "echo\n")
        let rights = try FileManager.default.attributesOfItem(atPath: target.path + "/tree/run.sh")[.posixPermissions]
        #expect(rights as? Int == Int(0o777 & UnpackFolder.allowed))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path + "/tree/link") == "run.sh")
    }

    /// A link that appears where a file is to go after the look for collisions is not written through.
    @Test
    internal func aLinkWhereAFileIsToGoIsNotWrittenThrough() throws {
        let archive = try archive("tree") { folder in
            try Data("a".utf8).write(to: folder.appending(name: "a.txt"))
            try Data("b".utf8).write(to: folder.appending(name: "b.txt"))
        }
        let target = try box.folder("target/tree")
        try box.file("target/tree/b.txt", "old")
        // While the user is asked about b.txt, a link takes the place where a.txt is to go.
        let result = try unpack(archive, into: box.url("target")) {
            try? FileManager.default.createSymbolicLink(
                atPath: target.appending(name: "a.txt").path,
                withDestinationPath: box.url("nowhere").path
            )
        }
        let refused = ArchiveError.unsupported("Unpacking over the symbolic link \(target.path)/a.txt")
        #expect(result.problems == ["tree/a.txt: \(refused.localizedDescription)"])
        #expect(!box.exists("nowhere") && box.read("target/tree/b.txt") == "b")
    }

    /// A link on the way to a folder is not gone through.
    @Test
    internal func aLinkOnTheWayIsNotGoneThrough() throws {
        let archive = try archive("tree") { folder in
            try FileManager.default.createDirectory(
                at: folder.appending(name: "sub"),
                withIntermediateDirectories: true
            )
            try Data("x".utf8).write(to: folder.appending(name: "sub/file.txt"))
        }
        let elsewhere = try box.folder("elsewhere")
        try box.folder("target")
        try FileManager.default.createSymbolicLink(
            atPath: box.url("target/tree").path,
            withDestinationPath: elsewhere.path
        )
        let result = try unpack(archive, into: box.url("target"))
        let link = box.url("target/tree").path
        #expect(
            result.problems.first == "tree: "
                + ArchiveError.unsupported("Unpacking through the symbolic link \(link)").localizedDescription
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    /// A target written with `..` is looked at where the disk takes it, not where its text
    /// would lead: a link at the place the text names is no reason to refuse.
    @Test
    internal func aTargetWithDotsIsLookedAtWhereItLeads() throws {
        let archive = try archive("tree") { try Data("x".utf8).write(to: $0.appending(name: "file.txt")) }
        let real = try box.folder("real/sub")
        try FileManager.default.createSymbolicLink(atPath: box.url("link").path, withDestinationPath: real.path)
        // By the text, link/../dest is <sandbox>/dest; on the disk it is real/dest.
        try box.folder("dest")
        try FileManager.default.createSymbolicLink(atPath: box.url("dest/tree").path, withDestinationPath: "/tmp")
        let target = URL(fileURLWithPath: box.root.path + "/link/../dest")
        let result = try unpack(archive, into: target)
        #expect(result.problems.isEmpty)
        #expect(box.read("real/dest/tree/file.txt") == "x")
    }

    /// On a server, links are left out and files arrive.
    @Test
    internal func onAServerLinksAreLeftOut() throws {
        let archive = try archive("tree") { folder in
            try Data("x".utf8).write(to: folder.appending(name: "file.txt"))
            try FileManager.default.createSymbolicLink(
                atPath: folder.appending(name: "link").path,
                withDestinationPath: "file.txt"
            )
        }
        let result = try unpack(archive, into: bench.memory.url("target"))
        #expect(result.problems.isEmpty)
        #expect(bench.memory.contents("target/tree/file.txt") == "x")
        #expect(try bench.names(bench.memory.url("target/tree")) == ["file.txt"])
    }

    /// A member whose writing to the server is cancelled leaves nothing there.
    @Test
    internal func aMemberWhoseWritingIsCancelledLeavesNothing() throws {
        let archive = try archive("tree") { try Data(count: 1 << 16).write(to: $0.appending(name: "file.bin")) }
        bench.memory.stallsWrites = true
        defer { bench.memory.releaseStalls() }
        let done = Signal<Bool>()
        let target = bench.memory.url("target")
        OtherThread.start {
            let result = try? unpack(archive, into: target)
            done.set(result?.cancelled == true)
        }
        #expect(Wait.until { bench.memory.stalledTransfers > 0 })
        bench.monitor.cancellation.cancel()
        #expect(done.wait(seconds: Wait.ceiling) == true)
        #expect(bench.memory.allPaths.allSatisfy { !$0.hasSuffix(".tmp") && !$0.hasSuffix("file.bin") })
    }

    /// A folder that another one makes in the same moment is used when it is a real folder.
    @Test
    internal func aFolderMadeByAnotherInTheSameMomentIsUsed() throws {
        let archive = try archive("tree") { try Data("x".utf8).write(to: $0.appending(name: "file.txt")) }
        let racing = CoverageArchivesFormatsRacingFileSystem()
        bench.fileSystems.register(racing)
        racing.inner.addDirectory("target/tree")
        racing.hidesOnce = "target/tree"
        let result = try unpack(archive, into: racing.inner.url("target"))
        #expect(result.problems.isEmpty && result.unpacked == 2)
        #expect(racing.inner.contents("target/tree/file.txt") == "x")
    }

    /// A file at the top of the archive arrives straight in the target; a link replaces what
    /// stands under its name when the user agrees.
    @Test
    internal func aTopFileArrivesAndALinkReplacesWhenAgreed() throws {
        let archive = try archive("tree") { folder in
            try FileManager.default.createSymbolicLink(
                atPath: folder.appending(name: "link").path,
                withDestinationPath: "elsewhere"
            )
        }
        try box.file("top.txt", "top")
        let top = box.url("top.zip")
        try bench.pack([box.url("top.txt")], to: top)
        let target = box.url("target")
        #expect(try unpack(top, into: target).problems.isEmpty)
        #expect(box.read("target/top.txt") == "top")
        try box.file("target/tree/link", "a file in the way")
        #expect(try unpack(archive, into: target).problems.isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path + "/tree/link") == "elsewhere")
    }

    /// Cancel between two blocks of a member written by path ends it, and nothing of it stays.
    @Test
    internal func cancelBetweenTwoBlocksEndsTheMember() throws {
        let archive = try archive("tree") { try Data(count: 3 << 20).write(to: $0.appending(name: "big.bin")) }
        let folder = try box.folder("target/tree")
        let monitor = CoverageArchivesFormatsMonitor()
        let flag = monitor.cancellation
        // Cancelled as soon as the first block has arrived in the temporary file.
        monitor.whenAsked {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let written = names.filter { $0.hasSuffix(".tmp") }
                .map { name in
                    (try? FileManager.default.attributesOfItem(atPath: folder.path + "/" + name)[.size] as? Int) ?? 0
                }
            if written.contains(where: { $0 > 0 }) {
                flag.cancel()
            }
        }
        let result = try unpack(archive, into: box.url("target"), monitor: monitor)
        #expect(result.cancelled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}

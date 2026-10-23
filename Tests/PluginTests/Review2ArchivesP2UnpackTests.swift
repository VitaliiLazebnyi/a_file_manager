import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Review round 2, second pass: unpacking from a folder's descriptor (L043), links on the way, absolute
/// paths and the rights of unpacked files.
@MainActor
@Suite
internal struct Review2ArchivesP2UnpackTests: ArchiveFixSuite {
    /// The archive file systems in a sandbox of their own.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// A link swapped in for a folder while a member is unpacked into it does not lead the member away (L043).
    @Test
    internal func aLinkPutInPlaceWhileAMemberIsUnpackedDoesNotLeadItAway() throws {
        let outside = try box.folder("outside")
        let target = try box.folder("target")
        let archive = try writeZip(
            "race.zip",
            members: [("dir/sub/planted.txt", 0o644), ("dir/sub/second.txt", 0o644), ("plain.txt", 0o644)]
        )
        let swapped = Collected<String>()
        let files = FileManager.default
        // The folder was looked at and opened; now somebody takes it away and puts a link
        // to another place where it stood.
        // The link takes the folder's name in one step (the two names are exchanged): the
        // members are unpacked by several threads, and were the name free for a moment, another
        // member's thread could make a new folder `dir` there, which is neither of the two
        // outcomes this test tells apart (seen once in a run under the address sanitizer).
        try files.createDirectory(at: outside.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let link = target.appendingPathComponent("dir.link")
        try files.createSymbolicLink(at: link, withDestinationURL: outside)
        let unpacker = Unpacker(
            fileSystems: bench.fileSystems,
            monitor: bench.monitor,
            options: UnpackOptions(),
            whileUnpacking: { entry in
                guard entry.path == "dir/sub/planted.txt", swapped.all.isEmpty else {
                    return
                }
                swapped.add(entry.path)
                if renamex_np(target.appendingPathComponent("dir").path, link.path, UInt32(RENAME_SWAP)) == 0 {
                    try? FileManager.default.moveItem(at: link, to: target.appendingPathComponent("taken"))
                }
            },
            askConflict: { _, _ in .overwrite }
        )
        let result = unpacker.run(
            [Unpacker.Source(archive: try bench.store.archive(at: archive, cancellation: nil))],
            into: target
        )
        #expect(swapped.all == ["dir/sub/planted.txt"])
        // Nothing arrived at the place the link points to.
        #expect(try files.contentsOfDirectory(atPath: outside.appendingPathComponent("sub").path).isEmpty)
        #expect(try files.contentsOfDirectory(atPath: outside.path) == ["sub"])
        // The member that was under way went into the folder that had been opened; whatever
        // came after the link stood there was refused, not sent through it.
        #expect(box.exists("target/taken/sub/planted.txt") && box.exists("target/plain.txt"))
        let late = box.exists("target/taken/sub/second.txt")
        #expect(late || result.problems.contains { $0.contains("second.txt") }, "\(result.problems)")
        #expect(isSymbolicLink(target.appendingPathComponent("dir")))
    }

    /// No member goes through a link on its way, whether it stood there before or the archive brought it.
    @Test
    internal func noLinkOnTheWayIsGoneThroughWhoeverMadeIt() throws {
        let outside = try box.folder("outside")
        let target = try box.folder("target")
        // A link two folders down, left there before.
        try box.folder("target/a/b")
        try FileManager.default.createSymbolicLink(
            at: target.appendingPathComponent("a/b/c"),
            withDestinationURL: outside
        )
        let zip = try writeZip("deep.zip", members: [("a/b/c/d/planted.txt", 0o644), ("a/b/fine.txt", 0o644)])
        var result = try bench.unpack(zip, to: target)
        #expect(
            result.unpacked >= 1 && box.exists("target/a/b/fine.txt") && !result.problems.isEmpty,
            "\(result.problems)"
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)

        // A link the archive brings itself, and a member that wants to go through it.
        var tar = HandMadeTar.link("door", to: outside.path, type: 50)
        tar.append(HandMadeTar.file("door/planted.txt", "hello"))
        tar.append(HandMadeTar.file("honest.txt", "hello"))
        tar.append(Data(count: 1_024))
        try tar.write(to: box.url("door.tar"))
        let second = try box.folder("second")
        result = try bench.unpack(box.url("door.tar"), to: second)
        // Either the link is there and the member was refused, or the member is in a folder
        // of that name below the target and the link was refused; never both, and nothing outside.
        #expect(box.read("second/honest.txt") == "hello" && result.problems.count == 1, "\(result.problems)")
        #expect(isSymbolicLink(second.appendingPathComponent("door")) != box.exists("second/door/planted.txt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        // Which of the two does not depend on chance: the files come first, the links after them.
        #expect(box.read("second/door/planted.txt") == "hello" && result.problems.first?.hasPrefix("door:") == true)
    }

    /// Members with absolute paths are listed without the slashes and unpacked below the target.
    @Test
    internal func membersWithAbsolutePathsLandBelowTheFolderThatIsUnpackedInto() throws {
        // Where the members claim to belong: a folder of the test, so a member that got
        // there would be seen (and would harm nothing).
        let claimed = try box.folder("claimed")
        let inner = String(claimed.path.dropFirst())
        let zip = try writeZip(
            "absolute.zip",
            members: [
                (claimed.path + "/evil.txt", 0o644), ("//" + inner + "/second.txt", 0o644), ("/top.txt", 0o644)
            ]
        )
        var tar = HandMadeTar.file("/" + String(repeating: "/", count: 3) + "tar-top.txt", "hello")
        tar.append(HandMadeTar.file("/claimed-by-tar/deep.txt", "hello"))
        tar.append(Data(count: 1_024))
        try tar.write(to: box.url("absolute.tar"))

        // Listed without the leading slashes…
        let opened = try bench.store.archive(at: zip, cancellation: nil)
        #expect(opened.entry(inner + "/evil.txt") != nil && opened.entry("top.txt") != nil)
        #expect(opened.entries.allSatisfy { !$0.path.hasPrefix("/") })
        // …and unpacked below the target, every one of them.
        let target = try box.folder("target")
        for archive in [zip, box.url("absolute.tar")] {
            let result = try bench.unpack(archive, to: target)
            #expect(result.problems.isEmpty, "\(result.problems)")
        }
        #expect(box.exists("target/" + inner + "/evil.txt") && box.exists("target/" + inner + "/second.txt"))
        #expect(
            box.exists("target/top.txt") && box.exists("target/tar-top.txt")
                && box.exists("target/claimed-by-tar/deep.txt")
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: claimed.path).isEmpty)
        #expect(
            !FileManager.default.fileExists(atPath: "/claimed-by-tar")
                && !FileManager.default.fileExists(atPath: "/top.txt")
        )
        // Everything that arrived lies below the target, links followed.
        let arrived =
            FileManager.default.enumerator(at: target, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        #expect(
            arrived.count >= 5 && arrived.allSatisfy { PathSafety.isContained($0, in: target, resolvingLinks: true) }
        )
    }

    /// Unpacked files get no rights beyond what new files get, and a link in a file's place is replaced.
    @Test
    internal func unpackedFilesGetNoRightsBeyondWhatNewFilesGet() throws {
        let zip = try writeZip(
            "open.zip",
            members: [("everyone.txt", 0o666), ("tool", 0o777), ("mine.txt", 0o600)]
        )
        let target = try box.folder("target")
        let result = try bench.unpack(zip, to: target)
        #expect(result.problems.isEmpty && result.unpacked == 3)
        let allowed = Int(UnpackFolder.allowed)
        #expect(
            permissionBits(box.url("target/everyone.txt")) == 0o666 & allowed
                && permissionBits(box.url("target/tool")) == 0o777 & allowed
        )
        #expect(permissionBits(box.url("target/mine.txt")) == 0o600)
        // (With the usual mask nobody else may write to them.)
        if allowed & 0o022 == 0 { #expect(permissionBits(box.url("target/everyone.txt")) & 0o022 == 0) }
        // A file that exists is replaced by the new one, also where a link stands in its place.
        try FileManager.default.removeItem(at: box.url("target/mine.txt"))
        try box.file("elsewhere.txt", "untouched")
        try FileManager.default.createSymbolicLink(
            at: box.url("target/mine.txt"),
            withDestinationURL: box.url("elsewhere.txt")
        )
        #expect(try bench.unpack(zip, to: target).problems.isEmpty)
        #expect(!isSymbolicLink(box.url("target/mine.txt")) && box.read("elsewhere.txt") == "untouched")
        // Nothing of the temporary names is left.
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: target.path).sorted() == [
                "everyone.txt", "mine.txt", "tool"
            ]
        )
    }

    /// A ZIP written record by record, for names and rights no packer would write.
    private func writeZip(_ name: String, members: [(name: String, permissions: UInt16)]) throws -> URL {
        let url = box.url(name)
        let output = try OutputFile(creating: url, mode: 0o600)
        let writer = ZipWriter(output, limits: .standard)
        for member in members {
            var record = ZipRecord.new(
                name: member.name,
                isDirectory: false,
                modified: Date(),
                permissions: member.permissions,
                isSymbolicLink: false
            )
            record.setName(member.name)
            try writer.end(try writer.begin(record, localExtra: nil, expectedSize: nil), record, headerChanged: false)
        }
        try writer.finish(comment: Data())
        try output.close(durably: false)
        return url
    }
}

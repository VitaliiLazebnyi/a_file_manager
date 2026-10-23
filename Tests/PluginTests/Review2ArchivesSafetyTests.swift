import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Review round 2: what an archive (or a file that only claims to be one) can do to the
/// program and to the disk: member paths, and unpacking through links.
@Suite
internal struct Review2ArchivesSafetyTests: ArchiveFixSuite {
    /// The archive file systems in a sandbox of their own.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// Member paths are cut at the byte, so a slash with a combining mark is still a separator (A005).
    @Test
    internal func pathsAreCutAtTheByteNotAtTheCharacter() {
        // A slash followed by a combining mark is one Character and still a separator.
        #expect(ArchiveTree.normalized("../\u{301}evil.txt") == nil)
        #expect(ArchiveTree.normalized("a/\u{301}b") == nil)
        #expect(ArchiveTree.normalized("a/\u{200D}b/c") == nil)
        // A character that binds what follows it hides the separator from the other side.
        #expect(ArchiveTree.normalized("a\u{0600}/b") == nil)
        #expect(ArchiveTree.normalized("a/../b") == nil && ArchiveTree.normalized("..") == nil)
        #expect(ArchiveTree.normalized("a/b\u{0}c") == nil)
        #expect(ArchiveTree.normalized("/abs//./x") == "abs/x")
        #expect(ArchiveTree.normalized("dir/é/日本.txt") == "dir/é/日本.txt")
        #expect(ArchiveTree.normalized("...") == "..." && ArchiveTree.normalized("a/..b") == "a/..b")
        #expect(ArchiveTree.name(of: "a/b/c.txt") == "c.txt" && ArchiveTree.parent(of: "a/b/c.txt") == "a/b")
        #expect(ArchiveTree.relative("a/b/c", to: "a") == "b/c" && ArchiveTree.relative("ab/c", to: "a") == nil)
        // Too deep, or too long: every name would be a folder kept under its whole path.
        #expect(
            ArchiveTree.normalized(Array(repeating: "a", count: ArchiveTree.maxDepth + 1).joined(separator: "/")) == nil
        )
        #expect(
            ArchiveTree.normalized(Array(repeating: "a", count: ArchiveTree.maxDepth).joined(separator: "/")) != nil
        )
        #expect(ArchiveTree.normalized(String(repeating: "x", count: ArchiveTree.maxPathBytes + 1)) == nil)
    }

    /// A slash with a combining mark cannot take a member out of the target folder, from a ZIP or a TAR (A030).
    @Test
    internal func aSlashWithACombiningMarkCannotLeaveTheTargetFolder() throws {
        let names = ["../\u{301}evil.txt", "ok/\u{301}hidden.txt", "fine.txt"]
        let zip = try writeZip("slash.zip", limits: .standard, names: names)
        var tar = Data()
        for name in names { tar.append(HandMadeTar.file(name, "data")) }
        tar.append(Data(count: 1_024))
        try tar.write(to: box.url("slash.tar"))
        var archives = [zip, box.url("slash.tar")]
        // The reproducers the fuzzer left, when they are there.
        let repro = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fuzz/repro/arch")
        for name in ["containment-slash-combining-mark.zip", "containment-slash-combining-mark.tar"] {
            let fixture = repro.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: fixture.path) else { continue }
            let copy = box.url("fuzz-" + name)
            try FileManager.default.copyItem(at: fixture, to: copy)
            archives.append(copy)
        }
        for (index, archive) in archives.enumerated() {
            let target = try box.folder("out\(index)/deep/target")
            _ = try bench.unpack(archive, to: target)
            let outside = try FileManager.default.subpathsOfDirectory(atPath: box.url("out\(index)").path)
                .filter { path in
                    !path.hasPrefix("deep/target") && path != "deep"
                }
            #expect(outside.isEmpty, "\(archive.lastPathComponent) wrote \(outside)")
        }
        #expect(box.exists("out0/deep/target/fine.txt") && box.exists("out1/deep/target/fine.txt"))
        #expect(
            Unpacker.lies(box.url("a/b"), below: box.url("a"))
                && !Unpacker.lies(box.url("a/../b"), below: box.url("a"))
        )
        #expect(
            !Unpacker.lies(box.url("ab"), below: box.url("a")) && !Unpacker.lies(box.url("a"), below: box.url("a"))
        )
    }

    /// Paths too deep are left out, and archives that would fill the memory are refused (A077).
    @Test
    internal func deepPathsAreRefusedBeforeTheyFillTheMemory() throws {
        // One member 300 folders deep is not shown (and costs nothing).
        let deep = Array(repeating: "d", count: 300).joined(separator: "/") + "/f.txt"
        let one = try writeZip("deep.zip", limits: .standard, names: [deep, "plain.txt"])
        #expect(
            try bench.names(bench.inside(one, "", scheme: ArchiveURL.writableScheme), showHidden: true) == ["plain.txt"]
        )
        // Many members, each with its own chain of long folder names, are refused as a whole.
        var names: [String] = []
        for member in 0..<160 {
            let part = String(format: "%03d", member) + String(repeating: "n", count: 12)
            names.append(Array(repeating: part, count: 250).joined(separator: "/"))
        }
        let many = try writeZip("chains.zip", limits: .standard, names: names)
        #expect { try bench.store.archive(at: many, cancellation: nil) } throws: { error in
            if case ArchiveError.unsupported = error {
                return true
            }
            return false
        }
        // An archive with more entries than the memory is to hold is refused, not read.
        bench.environment.maxEntries = 3
        let crowded = try writeZip("crowded.zip", limits: .standard, names: (0..<6).map { "f\($0).txt" })
        #expect(throws: ArchiveError.self) { try bench.store.archive(at: crowded, cancellation: nil) }
    }

    /// The order of the tree stays what the order numbers say while entries come, go and are renamed (A013).
    @Test
    internal func theOrderOfTheTreeIsKeptWhileEntriesComeAndGo() {
        var tree = ArchiveTree()
        var generator = SystemRandomNumberGenerator()
        for index in 0..<40 {
            tree.insert(ArchiveEntry(path: "d\(index % 7)/f\(index)", isDirectory: false), keepingOrder: false)
        }
        _ = tree.ordered
        for round in 0..<400 {
            let path = "d\(Int.random(in: 0..<7, using: &generator))/f\(Int.random(in: 0..<60, using: &generator))"
            switch round % 3 {
            case 0:
                tree.insert(ArchiveEntry(path: path, isDirectory: false), keepingOrder: false)

            case 1:
                tree.remove(path)

            default:
                // A rename: out, and in again elsewhere with the position it had.
                if var entry = tree.remove(path) {
                    entry.path = "moved/" + ArchiveTree.name(of: path) + "-\(round)"
                    tree.insert(entry, keepingOrder: true)
                }
            }
            let kept = tree.ordered.map(\.path)
            let sorted = tree.unordered.sorted { $0.order < $1.order }.map(\.path)
            #expect(kept == sorted)
            if kept != sorted { break }
        }
    }

    // MARK: Unpacking (A096, A097)

    /// Nothing is unpacked through a link that already stands in the target, and the links stay (A096).
    @Test
    internal func nothingIsUnpackedThroughALinkThatAlreadyStandsInTheTarget() throws {
        let outside = try box.folder("outside")
        let target = try box.folder("target")
        try FileManager.default.createSymbolicLink(
            at: target.appendingPathComponent("dir"),
            withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            atPath: target.appendingPathComponent("loose.txt").path,
            withDestinationPath: outside.path + "/nowhere.txt"
        )
        let archive = try writeZip(
            "through.zip",
            limits: .standard,
            names: ["dir/planted.txt", "loose.txt", "safe/ok.txt"]
        )
        let result = try bench.unpack(archive, to: target)
        #expect(result.problems.count == 1 && box.exists("target/safe/ok.txt"), "\(result.problems)")
        // Nothing went through either link: the one that stood where a file was to go was
        // replaced by the file (the bench answers "overwrite"), not followed.
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        let loose = target.appendingPathComponent("loose.txt").path
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: loose)) == nil)
        // The links are what they were.
        #expect(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: target.appendingPathComponent("dir").path))
                == outside.path
        )
    }
}

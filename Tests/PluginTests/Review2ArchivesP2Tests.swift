import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Review round 2, second pass: the compact directory and the names its records keep (A051, A076).
@MainActor
@Suite
internal struct Review2ArchivesP2Tests: ArchiveFixSuite {
    /// The archive file systems in a sandbox of their own.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// The compact tree answers like a plain table through thousands of changes, and reuses the places it frees.
    @Test
    internal func theTreeBehavesLikeAPlainTableWhilePlacesAreUsedAgain() {
        var tree = ArchiveTree()
        var model: [String: Bool] = [:]  // path → is a folder
        var generator = SystemRandomNumberGenerator()
        for round in 0..<3_000 {
            let path = [
                "d\(Int.random(in: 0..<5, using: &generator))",
                "e\(Int.random(in: 0..<4, using: &generator))",
                "f\(Int.random(in: 0..<30, using: &generator))"
            ]
            .joined(separator: "/")
            switch Int.random(in: 0..<4, using: &generator) {
            case 0, 1:
                tree.insert(ArchiveEntry(path: path, isDirectory: false, size: Int64(round)), keepingOrder: false)
                model[path] = false

            case 2:
                // Only what the tree's callers remove: a file, or a folder with nothing in it.
                if tree.remove(path) != nil { model[path] = nil }

            default:
                tree.update(path) { $0.size = -1 }
                #expect(tree.entry(path).map { $0.size == -1 } ?? true)
            }
            if round.isMultiple(of: 50), !matches(tree, model) {
                Issue.record("the tree and the table differ in round \(round)")
                break
            }
        }
        #expect(matches(tree, model))
        // A position that is taken leads to its path, one that is not leads nowhere.
        let some = tree.ordered[tree.count / 2]
        #expect(tree.path(atOrder: some.order) == some.path && tree.path(atOrder: 1 << 40) == nil)
        // The places that were given up are used again: the table does not grow with the changes.
        #expect(tree.unordered.count <= 5 * 4 * 30 + 5 * 4 + 5)
    }

    /// Whether `tree` holds what `model` (path: is a folder) says, with the folders above, in a sound order.
    private func matches(_ table: ArchiveTree, _ model: [String: Bool]) -> Bool {
        var tree = table
        let files = model.filter { !$0.value }.keys
        // Every folder above a file exists, made up or real.
        var folders = Set(model.filter(\.value).keys)
        for file in files {
            var parent = ArchiveTree.parent(of: file)
            while !parent.isEmpty {
                folders.insert(parent)
                parent = ArchiveTree.parent(of: parent)
            }
        }
        let expected = Set(files).union(folders)
        guard Set(tree.unordered.map(\.path)).isSuperset(of: expected), tree.count == tree.unordered.count else {
            return false
        }
        for folder in folders.union([""]) {
            let inside = Set(expected.filter { ArchiveTree.parent(of: $0) == folder }.map(ArchiveTree.name(of:)))
            let children = tree.children(of: folder)
            guard tree.isDirectory(folder), Set(children.map(\.name)).isSuperset(of: inside),
                children.allSatisfy({ ArchiveTree.parent(of: $0.path) == folder })
            else { return false }
        }
        // The order is the order of the positions, and each position leads back to its entry.
        let ordered = tree.ordered
        guard ordered.map(\.order) == ordered.map(\.order).sorted(), ordered.count == tree.count else {
            return false
        }
        return ordered.allSatisfy { tree.entry($0.path)?.order == $0.order }
    }

    /// A ZIP record keeps its name, extra field and comment byte for byte, also through a rewrite.
    @Test
    internal func aRecordKeepsItsNameAsItWasWritten() throws {
        var record = ZipRecord()
        // Valid text: kept as text, read back byte for byte.
        record.nameBytes = Data("dir/übung – 日本.txt".utf8)
        #expect(
            record.nameBytes == Data("dir/übung – 日本.txt".utf8) && record.nameLength == record.nameBytes.count
                && !record.isDirectory
        )
        // Not text at all (code page 437), a byte-order mark, a name that ends in a slash.
        let dos = Data([0x44, 0x49, 0x52, 0x5C, 0x81, 0x62, 0x65, 0x72, 0x2E, 0x74, 0x78, 0x74])
        record.nameBytes = dos
        #expect(record.nameBytes == dos && record.nameLength == 12 && record.name == "DIR\\über.txt")
        let marked = Data([0xEF, 0xBB, 0xBF]) + Data("bom.txt".utf8)
        record.nameBytes = marked
        #expect(record.nameBytes == marked && record.nameLength == 10)
        record.nameBytes = Data("folder/".utf8)
        #expect(record.isDirectory && record.nameLength == 7)
        record.nameBytes = Data()
        #expect(record.nameBytes.isEmpty && record.nameLength == 0 && !record.isDirectory)
        // Two names that are the same text to Swift and other bytes are two names.
        var (composed, decomposed) = (ZipRecord(), ZipRecord())
        composed.nameBytes = Data("é.txt".precomposedStringWithCanonicalMapping.utf8)
        decomposed.nameBytes = Data("é.txt".decomposedStringWithCanonicalMapping.utf8)
        #expect(!composed.hasSameHeader(as: decomposed) && composed.hasSameHeader(as: composed))
        // Extra fields and comment come back as they went in.
        record.extra = Data([0x55, 0x54, 5, 0, 1, 1, 2, 3, 4])
        record.comment = Data("a comment".utf8)
        #expect(
            record.extra == Data([0x55, 0x54, 5, 0, 1, 1, 2, 3, 4]) && record.extraLength == 9
                && record.comment == Data("a comment".utf8)
        )

        try expectOldNamesSurviveARewrite(dos)
    }

    /// Writes a member named `dos` in an old character set, adds one, and checks that the rewrite kept the
    /// name's bytes.
    private func expectOldNamesSurviveARewrite(_ dos: Data) throws {
        let url = box.url("names.zip")
        let output = try OutputFile(creating: url, mode: 0o600)
        let writer = ZipWriter(output, limits: .standard)
        var old = ZipRecord.new(
            name: "x",
            isDirectory: false,
            modified: Date(),
            permissions: 0o644,
            isSymbolicLink: false
        )
        old.nameBytes = dos
        old.flags &= ~ZipRecord.flagUTF8
        old.versionMadeBy = 20
        try writer.end(try writer.begin(old, localExtra: nil, expectedSize: nil), old, headerChanged: false)
        try writer.finish(comment: Data())
        try output.close(durably: false)
        #expect(
            try bench.names(bench.inside(url, "DIR", scheme: ArchiveURL.writableScheme), showHidden: true) == [
                "über.txt"
            ]
        )
        try write("new", to: bench.inside(url, "new.txt", scheme: ArchiveURL.writableScheme))
        #expect(bench.store.flushAll(cancellation: nil).isEmpty)
        let records = try ZipDirectory.read(RandomAccessFile(url, shownAs: nil), maxEntries: .max, check: nil).records
        #expect(records.map(\.nameBytes) == [dos, Data("new.txt".utf8)])
    }
}

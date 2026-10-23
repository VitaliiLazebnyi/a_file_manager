import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// Review 2, local file system: locked files and their copies, and moves between names of one file.
@Suite
internal struct Review2LocalLocksAndMoves {
    /// The file system under test.
    internal let local = LocalFileSystem()

    // MARK: Locks

    /// Locks the file at `url` as the Finder does.
    private func lock(_ url: URL) { chflags(url.path, UInt32(UF_IMMUTABLE)) }

    /// Unlocks everything at the top of `box`, so that it can be removed.
    private func unlockAll(in box: Sandbox) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: box.root.path) else {
            return
        }
        for name in names { lchflags(box.url(name).path, 0) }
    }

    /// A locked copy under its real name, and a folder given the flags of a locked one, stay
    /// locked: they are the user's.
    @Test
    internal func aLockedCopyThatKeptItsNameIsAsLockedAsItsSource() throws {
        let box = try Sandbox()
        defer { unlockAll(in: box) }
        let source = try box.file("src.txt", "data")
        lock(source)
        try local.copy(source, to: box.url("dst.txt")) { _ in true }
        #expect(box.url("dst.txt").itemStatus.st_flags & UInt32(UF_IMMUTABLE) != 0)
        // Not unlocked and deleted merely because it was copied by this file system.
        #expect(throws: (any Error).self) { try local.remove(box.url("dst.txt")) }
        #expect(throws: (any Error).self) {
            try local.move(box.url("dst.txt"), to: box.url("moved.txt"), replacing: false)
        }
        #expect(box.exists("dst.txt"))
        // A locked folder whose metadata was copied is the user's as well.
        let folder = try box.folder("srcdir")
        let copy = try box.folder("copydir")
        lock(folder)
        try local.copyMetadata(from: folder, to: copy)
        #expect(copy.itemStatus.st_flags & UInt32(UF_IMMUTABLE) != 0)
        #expect(throws: (any Error).self) { try local.remove(copy) }
        #expect(box.exists("copydir"))
    }

    /// A locked copy under a temporary name can be renamed to its real name, and then stays
    /// locked; an abandoned one can be removed.
    @Test
    internal func aLockedCopyUnderATemporaryNameCanBeGivenItsRealName() throws {
        let box = try Sandbox()
        defer { unlockAll(in: box) }
        let source = try box.file("src.txt", "data")
        lock(source)
        let temporary = box.url(".afm-\(UUID().uuidString).tmp")
        try local.copy(source, to: temporary) { _ in true }
        try local.move(temporary, to: box.url("final.txt"), replacing: false)
        #expect(box.url("final.txt").itemStatus.st_flags & UInt32(UF_IMMUTABLE) != 0)
        // The entry went with the rename: the file with its real name is refused now.
        #expect(throws: (any Error).self) { try local.remove(box.url("final.txt")) }
        // A temporary that is abandoned can be removed.
        let abandoned = box.url(".afm-\(UUID().uuidString).tmp")
        try local.copy(source, to: abandoned) { _ in true }
        try local.remove(abandoned)
        #expect(!box.exists(abandoned.lastPathComponent))
    }

    /// With more locked temporaries than the table holds, the recent ones can all still be
    /// renamed.
    @Test
    internal func theTableOfLockedTemporariesIsNeverWipedWholesale() throws {
        let box = try Sandbox()
        defer { unlockAll(in: box) }
        let source = try box.file("src.txt", "d")
        lock(source)
        let count = 4_096 + 40
        for number in 0..<count { try local.copy(source, to: box.url(".afm-\(number).tmp")) { _ in true } }
        // The recent ones are all still this file system's to rename (a wipe at 4,096 drops them).
        for number in (count - 30)..<count {
            try local.move(box.url(".afm-\(number).tmp"), to: box.url("done-\(number).txt"), replacing: false)
        }
        #expect(box.exists("done-\(count - 1).txt"))
    }

    // MARK: Moving

    /// A move onto another hard link of the same file leaves one name, and a change of case is
    /// a rename.
    @Test
    internal func movingOntoAnotherNameOfTheSameFileMovesIt() throws {
        let box = try Sandbox()
        let first = try box.file("a.txt", "same")
        let second = box.url("b.txt")
        try FileManager.default.linkItem(at: first, to: second)
        try local.move(first, to: second, replacing: true)
        #expect(!box.exists("a.txt") && box.read("b.txt") == "same")
        // A change of the letters' case is a rename and loses nothing.
        let upper = try box.file("Case.txt", "c")
        try local.move(upper, to: box.url("case.txt"), replacing: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: box.root.path).sorted()
        #expect(names == ["b.txt", "case.txt"] && box.read("case.txt") == "c")
    }

    /// A rename that changes only the case or the form of an accent keeps the file; a move onto
    /// its hard link in another folder still moves.
    @Test
    internal func aRenameOfOnlyTheLettersCaseOrTheFormOfAnAccentNeverRemovesTheFile() throws {
        let box = try Sandbox()
        let decomposed = "e\u{0301}.txt"
        let composed = "\u{00E9}.txt"
        // Replacing or not, accent to accent and case to case: the file is there afterwards, once.
        for replacing in [true, false] {
            let from = try box.file(replacing ? decomposed : "x" + decomposed, "accent")
            let target = box.url(replacing ? composed : "x" + composed)
            try local.move(from, to: target, replacing: replacing)
            let names = try FileManager.default.contentsOfDirectory(atPath: box.root.path)
            #expect(names.count == 1, "\(names)")
            #expect(try String(contentsOf: target, encoding: .utf8) == "accent")
            // And back the other way.
            try local.move(target, to: from, replacing: replacing)
            #expect(try String(contentsOf: from, encoding: .utf8) == "accent")
            try FileManager.default.removeItem(at: from)
        }
        for replacing in [true, false] {
            let from = try box.file("Mixed.txt", "case")
            try local.move(from, to: box.url("MIXED.txt"), replacing: replacing)
            #expect(try FileManager.default.contentsOfDirectory(atPath: box.root.path) == ["MIXED.txt"])
            #expect(box.read("mixed.txt") == "case")
            try FileManager.default.removeItem(at: box.url("MIXED.txt"))
        }
        // Two hard links in different folders: the move still moves.
        let linked = try box.file("one/a.txt", "linked")
        try box.folder("two")
        try FileManager.default.linkItem(at: linked, to: box.url("two/b.txt"))
        try local.move(linked, to: box.url("two/b.txt"), replacing: true)
        #expect(!box.exists("one/a.txt") && box.read("two/b.txt") == "linked")
    }
}

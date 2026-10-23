import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// Review 2, second pass: folders made on the local disks, and items removed inside a tree whose folders may be
/// swapped for links.
@Suite
internal struct Review2KernelP2LocalChanges {
    /// The local disks with the system's own probes, as the program uses them.
    internal let local = LocalFileSystem()

    // MARK: L029 — a folder that must be new

    /// A folder that must be new is made only where nothing, not even a dangling link, has its name.
    @Test
    internal func aFolderThatMustBeNewIsMadeOnlyWhereNothingHasItsName() throws {
        let box = try Sandbox()
        // Missing parents are made as usual; the last name must be free.
        try local.createDirectory(at: box.url("a/b/new"), exclusive: true)
        #expect(local.item(at: box.url("a/b/new"))?.isRealDirectory == true)
        #expect(throws: FileSystemError.self) { try local.createDirectory(at: box.url("a/b/new"), exclusive: true) }
        // A file of that name, and a link to a folder: both are "something is there".
        try box.file("a/file")
        #expect(throws: FileSystemError.self) { try local.createDirectory(at: box.url("a/file"), exclusive: true) }
        let outside = try box.folder("outside")
        try FileManager.default.createSymbolicLink(at: box.url("a/link"), withDestinationURL: outside)
        #expect(throws: FileSystemError.self) { try local.createDirectory(at: box.url("a/link"), exclusive: true) }
        // A dangling link has the name too, and nothing is made where it points.
        try FileManager.default.createSymbolicLink(
            atPath: box.url("a/dangling").path,
            withDestinationPath: box.url("elsewhere").path
        )
        #expect(throws: FileSystemError.self) { try local.createDirectory(at: box.url("a/dangling"), exclusive: true) }
        let inside = try FileManager.default.contentsOfDirectory(atPath: outside.path)
        #expect(!box.exists("elsewhere") && inside.isEmpty)
        // Through the protocol, with a flag.
        let provider: any FileSystemProvider = local
        try provider.createDirectory(at: box.url("c/new"), exclusive: true, cancellation: CancellationFlag())
        #expect(throws: FileSystemError.self) {
            try provider.createDirectory(at: box.url("c/new"), exclusive: true, cancellation: CancellationFlag())
        }
    }

    /// A folder that may be there already is made as before: an existing folder or a link to one is success.
    @Test
    internal func aFolderThatMayBeThereIsMadeAsBefore() throws {
        let box = try Sandbox()
        // The plain call keeps its contract: an existing folder, or a link to one, is success.
        try local.createDirectory(at: box.url("x/y/z"))
        try local.createDirectory(at: box.url("x/y/z"))
        try local.createDirectory(at: box.url("x/y/z"), exclusive: false)
        let outside = try box.folder("outside")
        try FileManager.default.createSymbolicLink(at: box.url("x/link"), withDestinationURL: outside)
        try local.createDirectory(at: box.url("x/link"))
        try local.createDirectory(at: box.url("x/link/below/deeper"))
        #expect(box.exists("outside/below/deeper"))
        // A file in the way is an error, whether it has the name or lies on the way to it.
        try box.file("x/file")
        #expect(throws: (any Error).self) { try local.createDirectory(at: box.url("x/file")) }
        #expect(throws: (any Error).self) { try local.createDirectory(at: box.url("x/file/below")) }
        #expect(box.read("x/file") == "x")
        // The rights are what the system gives a new folder.
        var (made, reference) = (stat(), stat())
        try FileManager.default.createDirectory(at: box.url("reference"), withIntermediateDirectories: true)
        #expect(lstat(box.url("x/y/z").path, &made) == 0 && lstat(box.url("reference").path, &reference) == 0)
        #expect(made.st_mode == reference.st_mode)
        // The root, and a path with a slash at its end.
        try local.createDirectory(at: URL(fileURLWithPath: "/"))
        try local.createDirectory(at: URL(fileURLWithPath: box.url("slash").path + "/", isDirectory: true))
        #expect(box.exists("slash"))
    }

    /// Many threads make the same folders at once without a failure, and of those that want one new folder, one
    /// gets it.
    @Test
    internal func manyThreadsMakeTheSameFoldersAtOnce() throws {
        let box = try Sandbox()
        let failures = Locked(0)
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            do { try local.createDirectory(at: box.url("shared/a/b/c/leaf\(index % 4)")) } catch {
                failures.withValue { $0 += 1 }
            }
        }
        #expect(failures.withValue { $0 } == 0)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: box.url("shared/a/b/c").path).sorted() == [
                "leaf0", "leaf1", "leaf2", "leaf3"
            ]
        )
        // Of many that want the same new folder, one gets it.
        let made = Locked(0)
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if (try? local.createDirectory(at: box.url("shared/only"), exclusive: true)) != nil {
                made.withValue { $0 += 1 }
            }
        }
        #expect(made.withValue { $0 } == 1)
    }

    // MARK: F043 — deleting inside a tree whose folders may be swapped for links

    /// An item of a tree is removed only where the tree really is: never through a folder swapped for a link, nor
    /// outside the tree.
    @Test
    internal func anItemOfATreeIsRemovedOnlyWhereTheTreeReallyIs() throws {
        let box = try Sandbox()
        try box.file("tree/sub/deep/a.txt")
        try box.file("tree/sub/b.txt")
        try box.file("tree/top.txt")
        try box.file("victim/deep/a.txt", "precious")
        try box.file("victim/b.txt", "precious")
        let (root, flag) = (box.url("tree"), CancellationFlag())
        // As long as the tree is what it was, items go at any depth, files and empty folders.
        try local.remove(box.url("tree/top.txt"), below: root, cancellation: flag)
        try local.remove(box.url("tree/sub/deep/a.txt"), below: root, cancellation: flag)
        try local.remove(box.url("tree/sub/deep"), below: root, cancellation: flag)
        #expect(!box.exists("tree/top.txt") && !box.exists("tree/sub/deep") && box.exists("tree/sub/b.txt"))
        // A folder of the tree is swapped for a link to somebody else's folder, after it was listed.
        try FileManager.default.moveItem(at: box.url("tree/sub"), to: box.url("aside"))
        try FileManager.default.createSymbolicLink(at: box.url("tree/sub"), withDestinationURL: box.url("victim"))
        #expect(throws: (any Error).self) {
            try local.remove(box.url("tree/sub/b.txt"), below: root, cancellation: flag)
        }
        #expect(throws: (any Error).self) {
            try local.remove(box.url("tree/sub/deep/a.txt"), below: root, cancellation: flag)
        }
        #expect(throws: (any Error).self) {
            try local.remove(box.url("tree/sub/deep"), below: root, cancellation: flag)
        }
        #expect(box.read("victim/b.txt") == "precious" && box.read("victim/deep/a.txt") == "precious")
        // The link itself is an entry of the tree like any other, and goes as a link.
        try local.remove(box.url("tree/sub"), below: root, cancellation: flag)
        #expect(!box.exists("tree/sub") && box.read("victim/b.txt") == "precious")
        // The top swapped for a link: nothing below it is touched through the link.
        try box.file("tree2/x.txt")
        try FileManager.default.moveItem(at: box.url("tree2"), to: box.url("aside2"))
        try FileManager.default.createSymbolicLink(at: box.url("tree2"), withDestinationURL: box.url("victim"))
        #expect(throws: (any Error).self) {
            try local.remove(box.url("tree2/b.txt"), below: box.url("tree2"), cancellation: flag)
        }
        #expect(box.read("victim/b.txt") == "precious")
        // Not below the root at all, by a path that only looks as if it were: refused.
        #expect(throws: (any Error).self) {
            try local.remove(box.url("tree/../victim/b.txt"), below: root, cancellation: flag)
        }
        #expect(throws: (any Error).self) { try local.remove(box.url("treeish"), below: root, cancellation: flag) }
        #expect(throws: (any Error).self) { try local.remove(root, below: root, cancellation: flag) }
        #expect(box.read("victim/b.txt") == "precious")
        // A folder that is not empty stays, as with the plain call; a set flag begins nothing.
        try box.file("tree/full/in.txt")
        #expect(throws: (any Error).self) { try local.remove(box.url("tree/full"), below: root, cancellation: flag) }
        let set = CancellationFlag()
        set.cancel()
        #expect(throws: CocoaError.self) {
            try local.remove(box.url("tree/full/in.txt"), below: root, cancellation: set)
        }
        #expect(box.exists("tree/full/in.txt"))
    }
}

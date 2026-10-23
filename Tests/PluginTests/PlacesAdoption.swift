import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import PlacesPlugin

/// The tree of the Places plugin: levels that come with their nodes, wide folders linked in
/// turns, and scans that stop at mounted volumes.
@Suite
internal struct PlacesAdoption {
    /// The levels a scan delivers off the main thread come with their nodes, and linking them makes the tree
    /// that setting the children made.
    @Test
    internal func levelsComeWithTheirNodesAndLinkLikeTheOldPath() throws {
        let box = try Sandbox()
        for path in ["a/b/c", "a/d", "e", "f/g", "a/b/h"] { try box.folder(path) }
        try box.file("a/file.txt")
        let scanner = TreeScanner(root: box.root, provider: LocalFileSystem(), batchSize: 2)
        // Written by the other thread before it signals, read here after the wait.
        nonisolated(unsafe) var levels: [TreeScanner.Level] = []
        // Written by the other thread before it signals, read here after the wait.
        nonisolated(unsafe) var offMain = true
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            scanner.run { batch in
                if Thread.isMainThread { offMain = false }
                levels += batch
            }
            done.signal()
        }
        #expect(done.wait(timeout: .now() + Wait.ceiling) == .success)
        #expect(offMain && levels.allSatisfy { $0.nodes.map(\.name) == $0.children })

        let linked = DirectoryTree(rootURL: box.root)
        for level in levels { linked.attach(level.nodes, ofPath: level.path) }
        let old = DirectoryTree(rootURL: box.root)
        for level in levels { old.setChildren(level.children, ofPath: level.path, sorted: level.isSorted) }
        #expect(linked.paths == old.paths && linked.paths == ["a", "a/b", "a/b/c", "a/b/h", "a/d", "e", "f", "f/g"])
        #expect(linked.count == old.count)
        for path in linked.paths {
            let (new, expected) = (try #require(linked.node(at: path)), try #require(old.node(at: path)))
            #expect(
                new.isScanned == expected.isScanned && new.depth == expected.depth
                    && linked.url(of: new) == old.url(of: expected)
            )
            #expect(new.parent === linked.node(at: path.split(separator: "/").dropLast().joined(separator: "/")))
        }
        let cached = DirectoryTree(rootURL: box.root, paths: linked.paths)
        #expect(cached.paths == linked.paths)
    }

    /// A wide folder is linked in turns of a bounded size, and a folder read by someone else in between is left alone.
    @Test
    internal func aWideFolderIsLinkedInBoundedTurns() {
        let names = (0..<25).map { "folder\($0)" }
        let nodes = DirectoryTree.makeNodes(names, sorted: false)
        let tree = DirectoryTree(rootURL: URL(fileURLWithPath: "/V"))
        var next = 0
        var turns = 0
        while next < nodes.count {
            let before = next
            next = tree.attach(nodes, ofPath: "", from: before, limit: 10)
            #expect(next - before <= 10)
            #expect(tree.root.isScanned == (next == nodes.count))
            turns += 1
        }
        #expect(turns == 3 && tree.count == 25)
        let whole = DirectoryTree(rootURL: URL(fileURLWithPath: "/V"))
        whole.setChildren(names, ofPath: "")
        #expect(
            tree.paths == whole.paths
                && zip(tree.root.children, whole.root.children)
                    .allSatisfy { piece, whole in
                        piece.name == whole.name && piece.indexInParent == whole.indexInParent
                    }
        )
        // A folder that was read by someone else in between is left alone.
        let other = DirectoryTree(rootURL: URL(fileURLWithPath: "/V"))
        other.attach(nodes, ofPath: "", from: 0, limit: 10)
        other.setChildren(["x"], ofPath: "")
        other.attach(nodes, ofPath: "", from: 10, limit: 10)
        #expect(other.paths == ["x"])
    }

    /// Linking a level again keeps what is known below its folders and drops the folders that are gone.
    @Test
    internal func attachingToAKnownFolderKeepsWhatIsBelowIt() {
        let tree = DirectoryTree(rootURL: URL(fileURLWithPath: "/V"), paths: ["a", "a/deep", "b"])
        tree.attach(DirectoryTree.makeNodes(["a", "c"], sorted: true), ofPath: "")
        #expect(tree.paths == ["a", "a/deep", "c"] && tree.count == 3 && tree.node(at: "c")?.parent === tree.root)
    }

    /// A scan lists a mounted volume as unread without entering it, and reads the tree of a volume it starts on.
    @Test
    internal func aScanDoesNotEnterAMountedVolume() throws {
        let box = try Sandbox()
        try box.folder("plain/sub")
        guard let image = MountedImage(in: box, at: "mounted") else {
            // Shown as skipped, not as passed: nothing was checked.
            // Fails rather than skips: a skip would leave what the test covers to chance.
            Issue.record("a disk image cannot be attached here (hdiutil)")
            return
        }
        try FileManager.default.createDirectory(
            at: image.mountPoint.appendingPathComponent("inside"),
            withIntermediateDirectories: true
        )
        let scanner = TreeScanner(root: box.root, provider: LocalFileSystem())
        let completed = scanner.run { _ in
            // What it found is checked below.
        }
        #expect(completed)
        #expect(scanner.paths.contains("mounted") && !scanner.paths.contains("mounted/inside"))
        #expect(scanner.unscanned == ["mounted"] && scanner.paths.contains("plain/sub"))
        // The tree of the volume itself is read.
        let own = TreeScanner(root: image.mountPoint, provider: LocalFileSystem())
        let ownCompleted = own.run { _ in
            // What it found is checked below.
        }
        #expect(ownCompleted && own.paths == ["inside"] && own.unscanned.isEmpty)
    }
}

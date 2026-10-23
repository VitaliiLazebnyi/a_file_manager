import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import PlacesPlugin

/// Reading trees from file systems and keeping them: these run on several threads.
@Suite
internal struct PlacesTreeScanning {
    /// What a scan put into a tree.
    internal struct Scan {
        /// The tree the levels of the scan were set in.
        internal let tree: DirectoryTree
        /// Whether the scan read everything.
        internal let completed: Bool
        /// How many times the scan handed over levels.
        internal let batches: Int
    }

    /// The file system the scans read.
    internal let memory = MemoryFileSystem()

    /// Runs a scan and puts what it delivers into a tree.
    internal func scan(_ scanner: TreeScanner, root: URL) -> Scan {
        let tree = DirectoryTree(rootURL: root)
        var batches = 0
        let completed = scanner.run { levels in
            batches += 1
            for level in levels {
                tree.setChildren(level.children, ofPath: level.path)
            }
        }
        return Scan(tree: tree, completed: completed, batches: batches)
    }

    /// A scan reads folders only, level by level, and hidden ones only when asked to.
    @Test
    internal func scansFoldersOnlyLevelByLevel() {
        memory.addFile("/V/a/file.txt")
        memory.addFile("/V/a/b/c/deep.txt")
        memory.addDirectory("/V/z")
        memory.addDirectory("/V/.hidden/inside")
        var order: [String] = []
        let scanner = TreeScanner(root: memory.url("/V"), provider: memory, batchSize: 1)
        #expect(scanner.run { levels in order += levels.map(\.path) })
        #expect(order == ["", "a", "z", "a/b", "a/b/c"])
        let result = scan(TreeScanner(root: memory.url("/V"), provider: memory), root: memory.url("/V"))
        #expect(result.completed && result.tree.paths == ["a", "a/b", "a/b/c", "z"])
        #expect(result.tree.node(at: "a/b/c")?.isScanned == true)
        let withHidden = scan(
            TreeScanner(root: memory.url("/V"), provider: memory, showHidden: true),
            root: memory.url("/V")
        )
        #expect(withHidden.tree.paths == [".hidden", ".hidden/inside", "a", "a/b", "a/b/c", "z"])
    }

    /// Folders left out of a scan are listed but not read.
    @Test
    internal func excludedFoldersAreListedButNotRead() {
        memory.addDirectory("/V/Volumes/Other/deep")
        memory.addDirectory("/V/keep/inner")
        let excluded = memory.url("/V/Volumes").locationKey
        let result = scan(
            TreeScanner(root: memory.url("/V"), provider: memory) { $0.locationKey == excluded },
            root: memory.url("/V")
        )
        #expect(result.tree.paths == ["keep", "keep/inner", "Volumes"])
        #expect(result.tree.node(at: "Volumes")?.isScanned == false && result.tree.node(at: "keep")?.isScanned == true)
        #expect(memory.listRequests(for: "/V/Volumes") == 0)
    }

    /// A wide tree is read and handed over in batches.
    @Test
    internal func wideTreesAreReadInBatches() {
        for folder in 0..<300 {
            for sub in 0..<3 { memory.addDirectory("/W/d\(folder)/s\(sub)") }
        }
        memory.listBatchDelay = 0.001
        memory.listBatchSize = 1
        let result = scan(
            TreeScanner(root: memory.url("/W"), provider: memory, batchSize: 64),
            root: memory.url("/W")
        )
        #expect(result.completed && result.tree.count == 1_200)
        #expect(
            result.tree.root.children.count == 300
                && result.tree.node(at: "d10")?.children.map(\.name) == ["s0", "s1", "s2"]
        )
        // One call for the root, five for the 300 folders, and so on: results come in batches.
        #expect(result.batches > 5)
        // Whether the folders of a batch were really read side by side depends on how many
        // threads the system has to spare, which other tests running at the same time use up;
        // `Concurrency.parallelMapUsesSeveralThreads` in the kernel tests checks that part alone.
    }

    /// Cancelling stops the scan, from its own handler or from another thread.
    @Test
    internal func cancellingStopsTheScan() {
        for folder in 0..<50 { memory.addDirectory("/C/d\(folder)/sub/deeper") }
        let scanner = TreeScanner(root: memory.url("/C"), provider: memory, batchSize: 10)
        var received = 0
        let completed = scanner.run { _ in
            received += 1
            scanner.cancellation.cancel()
        }
        #expect(!completed && received == 1)
        #expect(scanner.subfolders(of: memory.url("/C")).isEmpty)

        // Cancelled from another thread while it runs.
        memory.listBatchDelay = 0.02
        memory.listBatchSize = 1
        let second = TreeScanner(root: memory.url("/C"), provider: memory, batchSize: 4)
        // A thread of its own: the shared queues may be busy with other tests.
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.02)
            second.cancellation.cancel()
        }
        let secondCompleted = second.run { _ in
            // Only whether it was stopped matters here.
        }
        #expect(!secondCompleted)
    }

    /// A folder that cannot be read counts as empty; links and packages are left out.
    @Test
    internal func unreadableFoldersCountAsEmptyAndLinksAndPackagesAreLeftOut() throws {
        let box = try Sandbox()
        try box.folder("real/inner")
        try box.folder("Some.app/Contents")
        try box.file("real/file.txt")
        try FileManager.default.createSymbolicLink(at: box.url("link"), withDestinationURL: box.url("real"))
        try box.folder("locked/secret")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: box.url("locked").path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: box.url("locked").path)
        }
        let result = scan(TreeScanner(root: box.root, provider: LocalFileSystem()), root: box.root)
        #expect(result.completed && result.tree.paths == ["locked", "real", "real/inner"])
    }
}

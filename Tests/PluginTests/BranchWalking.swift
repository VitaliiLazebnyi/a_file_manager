import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import VirtualFoldersPlugin

/// The walk reads many directories at once: this suite is the one to run with the thread sanitizer.
@Suite
internal struct BranchWalking {
    /// The local file system and `memory`.
    internal let fileSystems = FileSystemRegistry()
    /// The tree most tests walk.
    internal let memory = MemoryFileSystem()

    /// A registry of the local file system and an empty memory one.
    internal init() {
        fileSystems.register(LocalFileSystem())
        fileSystems.register(memory)
    }

    /// The names a walk of `starts` lists, sorted.
    internal func names(_ starts: [BranchWalker.Start], _ walker: BranchWalker) throws -> [String] {
        var names: [String] = []
        try walker.walk(starts) { batch in
            names += batch.map(\.name)
            return true
        }
        return names.sorted()
    }

    /// Every file below is listed under its path in the branch with its real location; hidden files
    /// and the folders themselves only when asked for.
    @Test
    internal func listsEveryFileBelowWithItsRelativePathAndRealLocation() throws {
        memory.addFile("/A/one.txt")
        memory.addFile("/A/docs/in.txt", "inside")
        memory.addFile("/A/docs/deep/er/leaf.txt")
        memory.addFile("/A/.git/config")
        memory.addDirectory("/A/empty")
        let walker = BranchWalker(fileSystems: fileSystems, showHidden: false)
        var items: [FileItem] = []
        let visited = try walker.walk([BranchWalker.Start(memory.url("/A"))]) { batch in
            items += batch
            return true
        }
        #expect(items.map(\.name).sorted() == ["docs/deep/er/leaf.txt", "docs/in.txt", "one.txt"])
        #expect(items.first { $0.name == "docs/in.txt" }?.url == memory.url("/A/docs/in.txt"))
        #expect(items.first { $0.name == "docs/in.txt" }?.size == 6)
        #expect(Set(visited.map(\.path)) == ["/A", "/A/docs", "/A/docs/deep", "/A/docs/deep/er", "/A/empty"])
        #expect(
            try names(
                [BranchWalker.Start(memory.url("/A"))],
                BranchWalker(fileSystems: fileSystems, showHidden: true)
            )
            .contains(".git/config")
        )
        let withFolders = try names(
            [BranchWalker.Start(memory.url("/A"))],
            BranchWalker(fileSystems: fileSystems, showHidden: false, listsFolders: true)
        )
        #expect(
            withFolders == [
                "docs", "docs/deep", "docs/deep/er", "docs/deep/er/leaf.txt", "docs/in.txt", "empty", "one.txt"
            ]
        )
    }

    /// A tree of hundreds of folders is read completely, each file once, in more than one batch.
    @Test
    internal func aWideTreeIsReadCompletelyOnAllCores() throws {
        var expected: [String] = []
        for folder in 0..<300 {
            for file in 0..<3 {
                memory.addFile("/wide/d\(folder)/sub/f\(file).txt")
                expected.append("d\(folder)/sub/f\(file).txt")
            }
        }
        var batches = 0
        var names: [String] = []
        try BranchWalker(fileSystems: fileSystems, showHidden: false)
            .walk([BranchWalker.Start(memory.url("/wide"))]) { batch in
                batches += 1
                names += batch.map(\.name)
                return true
            }
        #expect(names.sorted() == expected.sorted())
        #expect(Set(names).count == names.count && batches > 1)
    }

    /// The walk ends after the batch the receiver did not want more after, leaves out what cannot be
    /// read, and throws for an unreadable start only when it must read it.
    @Test
    internal func stopsWhenNoMoreIsWantedAndSkipsWhatCannotBeRead() throws {
        for folder in 0..<200 { memory.addFile("/many/d\(folder)/f.txt") }
        var received = 0
        try BranchWalker(fileSystems: fileSystems, showHidden: false)
            .walk([BranchWalker.Start(memory.url("/many"))]) { batch in
                received += batch.count
                return false
            }
        #expect(received > 0 && received <= BranchWalker.directoriesPerBatch)

        memory.addFile("/part/ok/a.txt")
        memory.addFile("/part/locked/b.txt")
        memory.unreadable = ["/part/locked"]
        let walker = BranchWalker(fileSystems: fileSystems, showHidden: false)
        #expect(try names([BranchWalker.Start(memory.url("/part"))], walker) == ["ok/a.txt"])
        memory.unreadable = ["/part"]
        #expect(try names([BranchWalker.Start(memory.url("/part"))], walker).isEmpty)
        #expect(throws: (any Error).self) {
            try walker.walk([BranchWalker.Start(memory.url("/part"))], mustRead: true) { _ in true }
        }
    }

    /// A link to a folder is listed as an item, and a package is one item unless packages are entered.
    @Test
    internal func linksAreListedNotFollowedAndPackagesStayWhole() throws {
        let box = try Sandbox()
        try box.file("real/a.txt")
        try box.file("Tool.app/Contents/Info.plist")
        try FileManager.default.createSymbolicLink(at: box.url("loop"), withDestinationURL: box.root)
        let walker = BranchWalker(fileSystems: fileSystems, showHidden: false)
        #expect(try names([BranchWalker.Start(box.root)], walker) == ["Tool.app", "loop", "real/a.txt"])
        var entering = walker
        entering.entersPackages = true
        #expect(
            try names([BranchWalker.Start(box.root)], entering) == [
                "Tool.app/Contents/Info.plist", "loop", "real/a.txt"
            ]
        )
    }

    /// Eight listings of one branch at once, with the options set meanwhile, all see the whole branch.
    @Test
    internal func manyWalksAtOnceShareTheProvidersSafely() {
        for folder in 0..<40 { memory.addFile("/shared/d\(folder)/x/f.txt") }
        let virtual = VirtualFileSystem(fileSystems: fileSystems)
        let counts = Parallel.map(Array(0..<8)) { index -> Int in
            if index.isMultiple(of: 2) { virtual.options = VirtualFileSystem.Options(listsFolders: false) }
            return ((try? virtual.list(virtual.branch(of: memory.url("/shared")), showHidden: false)) ?? []).count
        }
        #expect(counts == Array(repeating: 40, count: 8))
    }
}

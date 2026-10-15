import Testing

@testable import ArchivesPlugin

/// The tree of an archive's members, asked about places that are no folders and about
/// members that share a position.
@Suite
internal struct CoverageArchivesFSTreeTests {
    private static func file(_ path: String, order: Int = 0) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: false, order: order)
    }

    /// A file is no folder: it has no children and nothing below it, and neither has a path
    /// that is not in the archive.
    @Test
    internal func aFileHasNoChildrenAndNothingBelowIt() {
        var tree = ArchiveTree()
        tree.insert(Self.file("folder/file.txt"))
        #expect(tree.hasChildren("folder") && tree.hasChildren(""))
        #expect(!tree.hasChildren("folder/file.txt") && !tree.hasChildren("missing"))
        #expect(tree.children(of: "folder/file.txt") == nil && tree.children(of: "missing") == nil)
        #expect(tree.descendants(of: "folder/file.txt").isEmpty && tree.descendants(of: "missing").isEmpty)
        #expect(tree.descendants(of: "").map(\.path).sorted() == ["folder", "folder/file.txt"])
    }

    /// A folder that is inserted as made up counts towards the bytes of such folders, until
    /// its real entry comes.
    @Test
    internal func aFolderThatIsMadeUpCountsWhenItIsInsertedAsSuch() {
        var tree = ArchiveTree()
        tree.insert(ArchiveEntry(path: "made/up", isDirectory: true, isImplicit: true))
        // Its own path, and the path of the folder above it that had to be made up for it.
        #expect(tree.implicitBytes == "made/up".utf8.count + "made".utf8.count)
        tree.insert(ArchiveEntry(path: "made/up", isDirectory: true))
        #expect(tree.implicitBytes == "made".utf8.count && tree.entry("made/up")?.isImplicit == false)
    }

    /// Two members that share a position stay in the order, and each is found when it goes.
    @Test
    internal func membersThatShareAPositionAreKeptApartInTheOrder() {
        var tree = ArchiveTree()
        tree.insert(Self.file("a", order: 5), keepingOrder: true)
        tree.insert(Self.file("b", order: 5), keepingOrder: true)
        tree.insert(Self.file("c", order: 7), keepingOrder: true)
        let shared = tree.ordered.map(\.path)
        #expect(Set(shared.prefix(2)) == ["a", "b"] && shared.last == "c")
        // The second of the two that share a position is found behind the first.
        tree.remove(shared[1])
        #expect(tree.ordered.map(\.path) == [shared[0], "c"])
        #expect(tree.path(atOrder: 7) == "c" && tree.path(atOrder: 6) == nil && tree.path(atOrder: 99) == nil)
    }
}

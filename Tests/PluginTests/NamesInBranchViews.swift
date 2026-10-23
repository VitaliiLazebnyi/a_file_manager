import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FileOperationsPlugin
@testable import VirtualFoldersPlugin

/// A branch view that names two files by their paths: the names of what a job processed are
/// found by location.
@MainActor
@Suite
internal struct NamesInBranchViews {
    /// Two files of the same name in different folders get different names in the view, and the
    /// names of processed items are looked up by their location, not by their last component.
    @Test
    internal func processedItemsAreFoundByLocationWhereNamesArePaths() throws {
        let registry = FileSystemRegistry()
        let memory = MemoryFileSystem()
        registry.register(memory)
        let virtual = VirtualFileSystem(fileSystems: registry)
        registry.register(virtual)
        memory.addFile("/A/x/same.txt")
        memory.addFile("/A/y/same.txt")
        memory.addFile("/A/other.txt")
        let picked = virtual.registerPicked(
            [memory.url("/A/x/same.txt"), memory.url("/A/y/same.txt"), memory.url("/A/other.txt")],
            in: memory.url("/A")
        )
        let items = try virtual.list(picked, showHidden: false)
        let (first, second) = (
            try #require(items.first { $0.url.path == "/A/x/same.txt" }),
            try #require(items.first { $0.url.path == "/A/y/same.txt" })
        )
        #expect(first.name != "same.txt" && second.name != "same.txt" && first.name != second.name)
        let names = FileOperations.names(of: [memory.url("/A/y/same.txt"), memory.url("/A/other.txt")], among: items)
        #expect(Set(names) == [second.name, "other.txt"])
    }
}

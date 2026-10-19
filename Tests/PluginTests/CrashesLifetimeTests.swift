import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import VirtualFoldersPlugin

/// What is left of a part of the program whose owner has gone while it still had work: it does
/// not read the owner (a read of a reference that is not kept ends the program).
@MainActor
internal struct CrashesLifetimeTests {
    /// The virtual file system outlives its registry when its work still runs (a list prepared in
    /// the background, a listing): then it finds no file systems, and lists nothing.
    @Test
    internal func aVirtualFolderWhoseRegistryHasGoneFindsNoFileSystems() throws {
        let memory = MemoryFileSystem()
        memory.addFile("/A/one.txt")
        var registry: FileSystemRegistry? = FileSystemRegistry()
        let virtual = VirtualFileSystem(fileSystems: try #require(registry))
        registry?.register(memory)
        let branch = virtual.branch(of: memory.url("/A"))
        #expect(try virtual.list(branch, showHidden: false).map(\.name) == ["one.txt"])
        registry = nil
        #expect(throws: (any Error).self) { try virtual.list(branch, showHidden: false) }
        #expect(virtual.volume(of: branch) == nil)
    }
}

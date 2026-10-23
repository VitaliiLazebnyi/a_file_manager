import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport

/// A registry with the local disk and an in-memory file system, as two plugins would provide.
internal func makeFileSystems() -> (FileSystemRegistry, MemoryFileSystem) {
    let fileSystems = FileSystemRegistry()
    let memory = MemoryFileSystem()
    fileSystems.register(LocalFileSystem())
    fileSystems.register(memory)
    return (fileSystems, memory)
}

/// The names in a folder of the local disk, hidden ones too, sorted.
internal func namesOnDisk(_ url: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
}

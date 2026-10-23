import AFMKernel
import LocalFileSystemPlugin

/// Registries for job tests: the local disk with the file systems a test brings.
extension FileSystemRegistry {
    /// A registry with the local disk and then each of `providers`.
    internal static func localDisk(and providers: any FileSystemProvider...) -> FileSystemRegistry {
        let fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
        for provider in providers {
            fileSystems.register(provider)
        }
        return fileSystems
    }
}

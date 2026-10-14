import AFMKernel
import Foundation

/// Provides the local disks and mounted volumes: everything reachable through a file path.
public final class LocalFileSystemPlugin: Plugin {
    public let name = "Local file system"

    public init() {}

    public func start(in kernel: Kernel) {
        kernel.fileSystems.register(LocalFileSystem())
    }
}

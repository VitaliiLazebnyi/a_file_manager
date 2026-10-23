public import AFMKernel
import Foundation

/// Provides the local disks and mounted volumes: everything reachable through a file path.
public final class LocalFileSystemPlugin: Plugin {
    /// The plugin's name, as the kernel lists it.
    public let name = "Local file system"

    /// A plugin that has registered nothing yet: the file system is made in `start(in:)`.
    public init() {
        // Nothing to set up before the kernel starts the plugin.
    }

    /// Registers the file system of this Mac with the kernel; on the main thread, once.
    public func start(in kernel: Kernel) {
        kernel.fileSystems.register(LocalFileSystem())
    }

    deinit {
        // Nothing to release: the kernel holds the file system it was given.
    }
}

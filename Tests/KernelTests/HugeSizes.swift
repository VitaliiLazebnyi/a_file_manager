import AFMKernel
import Foundation
import TestSupport

/// A file system that claims impossible sizes, as a crafted archive can: every file is
/// `Int64.max - 5` bytes long.
internal final class HugeSizes: MemoryBacked {
    /// The file system that holds the tree.
    internal let inner: MemoryFileSystem

    /// What `inner` can do.
    internal var capabilities: FileSystemCapabilities { inner.capabilities }

    /// Claims the sizes of the entries of `inner`.
    internal init(_ inner: MemoryFileSystem) {
        self.inner = inner
    }

    /// The entries of `inner`, each file with its impossible size.
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try inner.list(directory, showHidden: showHidden)
            .map { item in
                FileItem(
                    url: item.url,
                    name: item.name,
                    kind: .init(isDirectory: item.isDirectory),
                    stat: .init(size: item.isDirectory ? 0 : .max - 5)
                )
            }
    }

    deinit {
        // Nothing to release.
    }
}

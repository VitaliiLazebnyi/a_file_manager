import AFMKernel
import Foundation

/// One watched folder, from the moment watching it is asked of its file system.
///
/// Main thread only.
@MainActor
internal final class FolderWatch {
    /// The folder.
    internal let directory: URL
    /// What the file system returned; watching ends when it is let go of.
    internal var watcher: (any WatchToken)?
    /// The file system has not come back from setting the watch up.
    internal var isStarting = true
    /// A panel shows the folder.
    ///
    /// A watch that is no longer wanted while it is still being set up stays in the table until
    /// its file system has come back, so that no second one is ever asked for behind it.
    internal var isWanted = true

    /// The watch of `directory`, about to be set up.
    internal init(directory: URL) {
        self.directory = directory
    }

    deinit {
        // Nothing to release.
    }
}

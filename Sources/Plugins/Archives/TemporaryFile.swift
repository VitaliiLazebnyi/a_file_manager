import Foundation

/// A temporary file that disappears with the last object that refers to it.
///
/// `kept` is guarded by `lock`.
internal final class TemporaryFile: @unchecked Sendable {
    /// Where the file lies.
    internal let url: URL
    private let lock = NSLock()
    private var kept = false

    /// Takes charge of the file at `url`: it is removed when this object goes.
    internal init(_ url: URL) {
        self.url = url
    }

    /// The file stays on the disk after all.
    internal func keep() {
        lock.lock()
        kept = true
        lock.unlock()
    }

    deinit {
        if !kept { unlink(url.path) }
    }
}

import AFMKernel
import Foundation

/// A writer of the base file system that tells its `DeferredTarget` when the file is closed.
internal final class DeferredWriter: FileWriter {
    /// The base's writer.
    internal let inner: any FileWriter
    /// Told about the change.
    internal let owner: DeferredTarget
    /// The file written.
    internal let url: URL

    /// A writer that passes everything to `inner` and tells `owner` about `url` when closed.
    internal init(_ inner: any FileWriter, owner: DeferredTarget, url: URL) {
        self.inner = inner
        self.owner = owner
        self.url = url
    }

    /// Writes to the base.
    internal func write(_ data: Data) throws { try inner.write(data) }

    /// Closes in the base and notes the change.
    internal func close(attributes: FileAttributes) throws {
        try inner.close(attributes: attributes)
        owner.wrote(url)
    }

    /// Interrupts the base's writer.
    internal func interrupt() { inner.interrupt() }

    deinit {
        // Nothing to release.
    }
}

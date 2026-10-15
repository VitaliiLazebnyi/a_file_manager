import AFMKernel
import Foundation

/// A reader of a file whose disk fails: every read throws.
internal final class CoverageViewerBrokenReader: FileReader {
    /// Throws.
    internal func read(upToCount _: Int) throws -> Data? {
        throw CocoaError(.fileReadUnknown)
    }

    /// Nothing happens.
    internal func seek(to _: UInt64) {
        // Nothing to do.
    }

    /// Nothing is open.
    internal func close() {
        // Nothing to release.
    }

    deinit {
        // Nothing to release.
    }
}

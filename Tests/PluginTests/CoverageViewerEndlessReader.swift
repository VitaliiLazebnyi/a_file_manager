import AFMKernel
import Foundation

/// A reader of a stream that never ends: the same block, again and again.
internal final class CoverageViewerEndlessReader: FileReader {
    private let block = Data(repeating: 0x41, count: 1 << 20)

    /// The block, whatever was asked for.
    internal func read(upToCount _: Int) -> Data? {
        block
    }

    /// Streams cannot seek; nothing happens.
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

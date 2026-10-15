import AFMKernel
import Foundation

/// A reader of bytes in memory that tells what is done with it.
///
/// Unchecked: `position` is used by one thread at a time, as the protocol allows; the hooks are
/// set before the reader is handed out.
internal final class CoverageViewerReader: FileReader, @unchecked Sendable {
    private let data: Data
    private var position = 0
    /// Called with the data a read returns, before it returns it.
    private let onRead: @Sendable (Data) -> Void
    private let onClose: @Sendable () -> Void

    /// A reader of `data` that calls `onRead` with each block it returns and `onClose` when it is closed.
    internal init(
        _ data: Data,
        onRead: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.data = data
        self.onRead = onRead
        self.onClose = onClose
    }

    /// A reader of `data` that tells nothing.
    internal convenience init(_ data: Data) {
        self.init(
            data,
            onRead: { _ in
                // Nothing to tell.
            },
            onClose: {
                // Nothing to tell.
            }
        )
    }

    /// The next bytes; empty at the end.
    internal func read(upToCount count: Int) -> Data? {
        let block = data.subdata(in: position..<min(data.count, position + count))
        position += block.count
        onRead(block)
        return block
    }

    /// Goes to `offset`.
    internal func seek(to offset: UInt64) {
        position = min(data.count, Int(offset))
    }

    /// Tells `onClose`.
    internal func close() {
        onClose()
    }

    deinit {
        // Nothing to release.
    }
}

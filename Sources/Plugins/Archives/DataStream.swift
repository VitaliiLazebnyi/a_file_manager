import Foundation

/// A stream that holds a few bytes in memory.
internal final class DataStream: SeekableStream {
    private let all: Data
    private var data: Data

    /// A stream of the bytes of `data`, from the first.
    internal init(_ data: Data) {
        all = data
        self.data = data
    }

    /// The next bytes, up to `count`; nil at the end.
    internal func read(upToCount count: Int) -> Data? {
        guard !data.isEmpty else {
            return nil
        }
        let block = data.prefix(count)
        data = data.dropFirst(block.count)
        return Data(block)
    }

    /// Continues at `offset`; past the end means the end.
    internal func seek(to offset: UInt64) {
        data = all.dropFirst(Int(min(offset, UInt64(all.count))))
    }

    /// Does nothing: the bytes go with the stream.
    internal func close() {
        // Nothing to let go of: the bytes are freed with the stream.
    }

    deinit {
        // Nothing to release.
    }
}

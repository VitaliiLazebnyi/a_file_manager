import Foundation

/// Bytes that are in memory already: a text handed to the viewer, a small file.
internal final class DataByteSource: ByteSource {
    private let data: Data

    /// The number of bytes.
    internal var length: Int64 { Int64(data.count) }

    /// A source of `data` (copied when it is a slice, so its indices start at zero).
    internal init(_ data: Data) {
        // A slice keeps the indices of what it was cut from; a copy starts at zero.
        self.data = data.startIndex != 0 ? Data(data) : data
    }

    /// The bytes from `offset` on, at most `count`; never blocks or throws.
    internal func read(at offset: Int64, count: Int) -> Data {
        let lower = Int(max(0, min(offset, length)))
        let upper = min(data.count, lower + max(0, count))
        return data.subdata(in: lower..<upper)
    }

    deinit {
        // Nothing to release.
    }
}

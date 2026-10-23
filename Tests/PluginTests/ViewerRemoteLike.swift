import Foundation

@testable import ViewerPlugin

/// A file that is "far away": every byte that is read from it is counted.
internal final class ViewerRemoteLike: ByteSource {
    /// The bytes of the file.
    internal let data: Data
    private let counter = ViewerAdoptBox((bytes: Int64(0), requests: 0))

    /// The size of the file in bytes.
    internal var length: Int64 { Int64(data.count) }
    /// The bytes read from the file so far.
    internal var fetched: Int64 { counter.value.bytes }
    /// The reads made so far.
    internal var requests: Int { counter.value.requests }

    /// A file of these bytes, nothing read from it yet.
    internal init(_ data: Data) { self.data = data }

    /// Text of lines of 10 to 150 characters, some with tabs and some with accents: the sort of
    /// file whose layout depends on the width of the window.
    internal static func text(megabytes: Int) -> Data {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(truncatingIfNeeded: state >> 11) & 0x7FFF_FFFF
        }
        let words = [
            "alpha", "beta", "gamma", "delta", "epsilon", "request", "handled", "user", "session", "0x7fff", "ä",
            "größe", "x"
        ]
        var bytes: [UInt8] = []
        bytes.reserveCapacity(megabytes << 20)
        while bytes.count < megabytes << 20 {
            let target = 10 + next() % 140
            var line = 0
            while line < target {
                let word = Array(words[next() % words.count].utf8)
                bytes.append(contentsOf: word)
                bytes.append(next().isMultiple(of: 40) ? 0x09 : 0x20)
                line += word.count + 1
            }
            bytes.append(0x0A)
        }
        return Data(bytes)
    }

    /// The bytes from `offset` on, at most `count`, counted as fetched.
    internal func read(at offset: Int64, count: Int) -> Data {
        let lower = Int(max(0, min(offset, length)))
        let upper = min(data.count, lower + max(0, count))
        counter.mutate { tally in
            tally.bytes += Int64(upper - lower)
            tally.requests += 1
        }
        return data.subdata(in: lower..<upper)
    }

    deinit {
        // Nothing to release.
    }
}

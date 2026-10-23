import Foundation

/// Bytes read from front to back: a part of a file, the output of a decompressor or of a
/// child process.
///
/// A stream belongs to the thread that reads it.
internal protocol ByteStream: AnyObject {
    /// The next block, never empty; nil at the end.
    func read(upToCount count: Int) throws -> Data?
    /// Passes over bytes without looking at them.
    func skip(_ count: UInt64) throws
    /// Ends the reading: what the stream holds (a child process, a decompressor's source) is let go.
    func close()
}

/// Skipping by reading, and reading a block of an exact size.
extension ByteStream {
    /// Passes over `count` bytes by reading them; throws when the stream ends before.
    internal func skip(_ count: UInt64) throws {
        var left = count
        while left > 0 {
            guard let block = try read(upToCount: Int(min(left, 1 << 18))) else {
                throw ArchiveError.damaged("unexpected end of data")
            }
            left -= UInt64(block.count)
        }
    }

    /// Exactly `count` bytes, or fewer at the end of the stream.
    internal func readFully(_ count: Int) throws -> Data {
        var data = Data()
        while data.count < count, let block = try read(upToCount: count - data.count) { data.append(block) }
        return data
    }
}

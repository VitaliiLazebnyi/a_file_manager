import Foundation

/// A stretch of a file as a stream; skipping costs nothing.
internal final class FileRangeStream: SeekableStream {
    private let file: RandomAccessFile
    private let start: UInt64
    private var position: UInt64
    private let end: UInt64

    /// The `length` bytes of `file` from `offset` on, or all to the end of the file when `length` is nil.
    ///
    /// A stretch that reaches past the end of the file (a damaged directory) ends with the file.
    internal init(_ file: RandomAccessFile, offset: UInt64, length: UInt64?) {
        self.file = file
        let first = min(offset, file.size)
        start = first
        position = first
        end = length.map { min(file.size, first.plusClamped($0)) } ?? file.size
    }

    /// Continues at `offset` within the stretch; past its end means its end.
    internal func seek(to offset: UInt64) {
        position = min(end, start.plusClamped(offset))
    }

    /// The next bytes of the stretch, up to `count`; nil at its end or where the file ends early.
    internal func read(upToCount count: Int) throws -> Data? {
        guard position < end else {
            return nil
        }
        let data = try file.read(at: position, count: Int(min(UInt64(count), end - position)))
        guard !data.isEmpty else {
            return nil
        }
        position += UInt64(data.count)
        return data
    }

    /// Moves on by `count` bytes without reading; throws when the stretch has fewer left.
    internal func skip(_ count: UInt64) throws {
        guard end - position >= count else { throw ArchiveError.damaged("unexpected end of data") }
        position += count
    }

    /// Does nothing: the file belongs to whoever opened it.
    internal func close() {
        // Nothing to let go of: the file is closed when its last reader lets go of it.
    }

    deinit {
        // Nothing to release.
    }
}

import Compression
import Foundation

/// Decompresses an `.xz` file; several streams in a row are read as one.
internal final class XZStream: ByteStream {
    private let source: any ByteStream
    private let coder: XZCoder
    private var pending = Data()
    private var sourceEnded = false
    private var isFinished = false
    /// What the coder delivered beyond what was asked for, and how much of it was handed on.
    private var ready = Data()
    private var readyOffset = 0
    private let control: StreamInterrupt?

    /// Decompresses `source`; with a `control`, a read ends with an error once the request is set.
    ///
    /// Throws when the system cannot start a decoder.
    internal init(_ source: any ByteStream, control: StreamInterrupt?) throws {
        self.source = source
        self.control = control
        coder = try XZCoder(encoding: false, algorithm: COMPRESSION_LZMA)
    }

    /// The next decompressed bytes, never more than `count`; nil at the end.
    ///
    /// The coder delivers in blocks of its own size, and a reader that asks for one TAR header must get no
    /// more than that.
    internal func read(upToCount count: Int) throws -> Data? {
        if readyOffset >= ready.count {
            guard let more = try decode(upToCount: count) else {
                return nil
            }
            if more.count <= count {
                return more
            }
            (ready, readyOffset) = (more, 0)
        }
        let end = min(ready.count, readyOffset + max(count, 1))
        defer { readyOffset = end }
        return ready.subdata(in: ready.startIndex + readyOffset..<ready.startIndex + end)
    }

    private func decode(upToCount count: Int) throws -> Data? {
        while !isFinished {
            try control?.check()
            if pending.isEmpty, !sourceEnded {
                if let block = try source.read(upToCount: 1 << 16) { pending = block } else { sourceEnded = true }
            }
            // Never told that the input ends: a stream says itself where it ends, and the
            // decoder then waits for more of one that is cut off, which is told apart below.
            let result = try coder.process(pending, finish: false, limit: max(count, 1 << 16))
            pending = Data(pending.dropFirst(result.consumed))
            if result.ended {
                // Padding between streams is made of zero bytes, however many: read on until
                // something else comes, or the file ends.
                while true {
                    // Cut at the first byte that is not padding, in one step.
                    pending = pending.firstIndex { $0 != 0 }.map { Data(pending[$0...]) } ?? Data()
                    guard pending.isEmpty, !sourceEnded else { break }
                    try control?.check()
                    if let block = try source.read(upToCount: 1 << 16) { pending = block } else { sourceEnded = true }
                }
                if pending.isEmpty, sourceEnded { isFinished = true } else { try coder.restart() }
            } else if result.output.isEmpty, sourceEnded, pending.isEmpty {
                throw ArchiveError.damaged("the compressed data ends too early")
            }
            if !result.output.isEmpty {
                return result.output
            }
        }
        return nil
    }

    /// Closes the source.
    internal func close() {
        source.close()
    }

    deinit {
        // Nothing to release.
    }
}

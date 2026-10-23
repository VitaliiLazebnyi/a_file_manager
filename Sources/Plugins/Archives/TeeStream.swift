import Foundation

/// Passes a stream on and keeps a copy of what was read in a file, for as long as the copy
/// stays below `limit` (and the disk takes it).
///
/// Used by one thread.
internal final class TeeStream: ByteStream {
    private let source: any ByteStream
    private let output: OutputFile
    private let limit: UInt64
    /// False once the copy was given up; what the file holds is then worthless.
    internal private(set) var isComplete = true

    private let room: SpaceWatch?

    /// Copies what is read from `source` into `output` while the copy stays below `limit` bytes and,
    /// with a `room`, while the volume has room for it.
    internal init(_ source: any ByteStream, to output: OutputFile, limit: UInt64, room: SpaceWatch?) {
        self.source = source
        self.output = output
        self.limit = limit
        self.room = room
    }

    /// The source's next block, written to the copy too unless the copy was given up.
    internal func read(upToCount count: Int) throws -> Data? {
        guard let block = try source.read(upToCount: count) else {
            return nil
        }
        if isComplete {
            if output.position.plusClamped(UInt64(block.count)) > limit || room?.allows(UInt64(block.count)) == false {
                isComplete = false
            } else {
                do { try output.write(block) } catch { isComplete = false }
            }
            // A copy that is given up frees its room now, not when the archive is let go.
            if !isComplete { output.discard() }
        }
        return block
    }

    /// Closes the source; the copy is the caller's to close.
    internal func close() { source.close() }

    deinit {
        // Nothing to release.
    }
}

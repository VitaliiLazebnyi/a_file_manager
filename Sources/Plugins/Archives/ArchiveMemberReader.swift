import AFMKernel
import Foundation

/// A `FileReader` over a member of an archive.
///
/// Members are streams: reading on is cheap, going back means starting again from the front, and a
/// member behind a long stretch of decompression is a long way off. Used by one thread; only
/// `interrupt()` may be called from another, which ends the read or seek that is under way and
/// every later one.
///
/// Unchecked: used by one thread at a time, as `FileReader` allows; `interrupt` touches only
/// `slot`, which is safe from any thread.
internal final class ArchiveMemberReader: FileReader, @unchecked Sendable {
    private let open: (InterruptSlot) throws -> any ByteStream
    private let slot = InterruptSlot()
    private var stream: (any ByteStream)?
    private var position: UInt64 = 0

    /// Opens the member with `open` at once, so that a missing password or a damaged header fails
    /// here; `cancellation` ends the opening (and only that) once it is set.
    internal init(cancellation: CancellationFlag?, _ open: @escaping (InterruptSlot) throws -> any ByteStream)
        throws
    {
        self.open = open
        let registration = cancellation?.onCancel { [weak slot] in slot?.interrupt() }
        defer {
            withExtendedLifetime(registration) {
                // Listened to until the opening is over.
            }
        }
        stream = try open(slot)
        do { try checkInterrupted() } catch {
            closeStream()
            throw error
        }
    }

    private func checkInterrupted() throws {
        if slot.isInterrupted { throw ArchiveError.cancelled }
    }

    /// Ends the read or seek under way and every later one; any thread.
    internal func interrupt() {
        slot.interrupt()
    }

    /// The next bytes of the member, at most `count`; nil at its end.
    ///
    /// A reader that was closed opens the member again from the front.
    internal func read(upToCount count: Int) throws -> Data? {
        try checkInterrupted()
        if stream == nil { stream = try open(slot) }
        guard let block = try stream?.read(upToCount: count) else {
            return nil
        }
        position += UInt64(block.count)
        return block
    }

    /// Moves to `offset` in the member: at once where the member lies in a file as it is, else by
    /// reading on, or from the front when the place lies behind.
    internal func seek(to offset: UInt64) throws {
        try checkInterrupted()
        if stream == nil {
            stream = try open(slot)
            position = 0
        }
        // A member that lies in a file as it is (TAR, an unpacked copy) is read at any place.
        if let seekable = stream as? (any SeekableStream) {
            seekable.seek(to: offset)
            position = offset
            return
        }
        if offset < position {
            closeStream()
            stream = try open(slot)
            position = 0
        }
        while position < offset {
            try checkInterrupted()
            guard let block = try stream?.read(upToCount: Int(min(offset - position, 1 << 18))) else { break }
            position += UInt64(block.count)
        }
    }

    /// Lets go of the member's stream.
    internal func close() {
        closeStream()
    }

    /// The slot lets go of the stream first: a stream that is kept for the next reader must
    /// not hear of a request that comes after this reader is done with it.
    private func closeStream() {
        slot.release()
        stream?.close()
        stream = nil
    }

    deinit {
        // Nothing to release: the owner closes the reader.
    }
}

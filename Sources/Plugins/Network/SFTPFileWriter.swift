import AFMKernel
import Foundation

/// A file being written over SFTP.
///
/// The write requests are not waited for one by one: up to a window of them are under way, and
/// their answers are collected as they arrive, in the next call or at the latest when the file is
/// closed. A refusal is therefore reported by a later `write` or by `close`.
///
/// Requests that follow a refused one are already on their way and may well be carried out, which
/// would leave a file with a gap of nothing in it. On the first failure the file is therefore
/// cut back to the first byte that was not confirmed: what is left on the server is a true
/// start of the file, and continuing it later is safe. `close` reports success only when every
/// write was confirmed, the server's length is the length written, and the server confirmed
/// the closing itself (which is where a full disk or a quota shows on some servers).
/// Used by one thread at a time, as `FileWriter` allows; `interrupt` only sets the flag, which is
/// safe from any thread.
internal final class SFTPFileWriter: FileWriter, @unchecked Sendable {
    /// One write request that is not confirmed yet.
    private struct Piece {
        let ticket: SFTPChannel.Ticket
        let offset: UInt64
        let length: Int
    }

    private let session: SFTPSession
    private let channel: SFTPChannel
    private var handle: Data?
    private var position: UInt64 = 0
    /// The requests whose answers are still to come, oldest first.
    private var outstanding: [Piece] = []
    private var failure: any Error?
    private var window = TransferWindow()
    private var depth = 4
    /// Set by `interrupt`; see `SFTPFileReader`.
    private let abort = CancellationFlag()

    /// A writer of the file `handle` stands for, opened on `channel` of `session`, that writes from
    /// `position` on.
    internal init(session: SFTPSession, channel: SFTPChannel, handle: Data, position: UInt64) {
        self.session = session
        self.channel = channel
        self.handle = handle
        self.position = position
    }

    /// Sends `data` in blocks after what was written before; a refusal of an earlier block is thrown.
    internal func write(_ data: Data) throws {
        guard let handle else { throw NetworkError.connectionLost }
        let block = SFTPSession.blockSize
        depth = min(SFTPSession.window, depth * 2)
        var offset = 0
        while offset < data.count {
            try collect(keeping: min(depth, window.limit(block: block)) - 1, handle: handle)
            let end = min(offset + block, data.count)
            let piece = data[data.startIndex + offset..<data.startIndex + end]
            let start = position + UInt64(offset)
            do {
                let ticket = try channel.send(.write, cancellation: abort) { encoder in
                    encoder.bytes(handle)
                    encoder.u64(start)
                    encoder.bytes(piece)
                }
                outstanding.append(Piece(ticket: ticket, offset: start, length: piece.count))
            } catch {
                fail(error, firstUnconfirmed: outstanding.first?.offset ?? start, handle: handle)
                throw error
            }
            offset = end
        }
        position += UInt64(data.count)
    }

    /// Waits for every write, sets the date and permissions, checks the length and closes the file.
    ///
    /// Throws when a write or the closing was refused, or the server's length is not the length written.
    internal func close(attributes: FileAttributes) throws {
        guard let handle else {
            return
        }
        do {
            try collect(keeping: 0, handle: handle)
        } catch {
            // The cut is in line already; the handle follows it.
            self.handle = nil
            session.closeHandle(handle, on: channel)
            throw error
        }
        self.handle = nil
        var changes = SFTPAttributes()
        changes.modified = attributes.modified.map { UInt32(clamping: Int64($0.timeIntervalSince1970)) }
        changes.permissions = attributes.permissions.map { UInt32($0 & 0o7777) }
        // Date and permissions, the question for the length, and the closing go out together
        // and are answered in that order, so a small file costs one round trip, not three.
        var closing: SFTPChannel.Ticket?
        let courtesy: SFTPChannel.Ticket?
        let length: SFTPChannel.Ticket
        do {
            // Date and permissions are a courtesy; a server that refuses them still has the file.
            courtesy =
                changes.modified != nil || changes.permissions != nil
                ? try channel.send(.fsetstat, cancellation: abort) { encoder in
                    encoder.bytes(handle)
                    encoder.attributes(changes)
                } : nil
            length = try channel.send(.fstat, cancellation: abort) { $0.bytes(handle) }
            closing = try channel.send(.close, cancellation: abort) { $0.bytes(handle) }
        } catch {
            if closing == nil { session.closeHandle(handle, on: channel) }
            throw error
        }
        if let courtesy { _ = try? channel.wait(for: courtesy, timeout: session.timeout, cancellation: abort) }
        let measured = try? channel.wait(for: length, timeout: session.timeout, cancellation: abort)
        // The closing is the server's last word on the file: an error here is an error of the upload.
        if let closing { try channel.wait(for: closing, timeout: session.timeout, cancellation: abort).checkStatus() }
        if let measured, var found = try? measured.expect(.attributes), let size = try? found.attributes().size,
            size != position
        {
            throw NetworkError.unexpected("the file on the server has \(size) bytes after the upload, not \(position)")
        }
    }

    /// Ends a wait for the server, from any thread; the file is then cut back as after a failure.
    internal func interrupt() { abort.cancel() }

    /// Records the first failure, gives up the requests under way, and has the server cut the
    /// file back to `firstUnconfirmed`.
    ///
    /// The cut is put in line behind the writes that are under way and is not waited for: the
    /// server may not be answering.
    private func fail(_ error: any Error, firstUnconfirmed: UInt64, handle: Data) {
        guard failure == nil else {
            return
        }
        failure = error
        for piece in outstanding {
            channel.abandon(piece.ticket)
        }
        outstanding = []
        var cut = SFTPAttributes()
        cut.size = firstUnconfirmed
        channel.sendWithoutAnswer(.fsetstat) { encoder in
            encoder.bytes(handle)
            encoder.attributes(cut)
        }
    }

    /// Takes the answers that have arrived, and waits for the oldest while more than `keep`
    /// are outstanding.
    ///
    /// The first failure is kept and thrown from then on.
    private func collect(keeping keep: Int, handle: Data) throws {
        if abort.isCancelled {
            fail(NetworkError.cancelled, firstUnconfirmed: outstanding.first?.offset ?? position, handle: handle)
        }
        if let failure { throw failure }
        while let oldest = outstanding.first {
            do {
                let packet: SFTPPacket
                if let arrived = channel.poll(oldest.ticket) {
                    packet = arrived
                } else if outstanding.count > keep {
                    packet = try channel.wait(for: oldest.ticket, timeout: session.timeout, cancellation: abort)
                } else {
                    return
                }
                try packet.checkStatus()
                outstanding.removeFirst()
                window.moved(oldest.length)
            } catch {
                fail(error, firstUnconfirmed: oldest.offset, handle: handle)
                throw error
            }
        }
    }

    deinit {
        // Dropped without `close`: like a failure, and the handle is closed, which never waits.
        guard let handle else {
            return
        }
        if failure == nil {
            fail(NetworkError.cancelled, firstUnconfirmed: outstanding.first?.offset ?? position, handle: handle)
        }
        session.closeHandle(handle, on: channel)
    }
}

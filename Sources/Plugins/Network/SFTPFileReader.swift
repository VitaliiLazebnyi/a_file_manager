import AFMKernel
import Foundation

/// A file being read over SFTP.
///
/// A window of read requests is kept under way, also between two calls: when the caller has taken
/// one piece the next ones are already on their way, so the speed does not depend on the delay of
/// one round trip. Nothing is read ahead for the first read after opening or after a jump (a viewer
/// that shows one page asks for one page); from the second read in a row on, the window grows, up
/// to what the line carries (`TransferWindow`). Seeking discards what was read ahead. Used by one
/// thread; `close` and `interrupt` never wait for the server.
///
/// Used by one thread at a time, as `FileReader` allows; `interrupt` only sets the flag, which is
/// safe from any thread.
internal final class SFTPFileReader: FileReader, @unchecked Sendable {
    /// One read request: the bytes `offset ..< offset + length` of the file.
    private struct Chunk {
        let offset: UInt64
        let length: Int
        let ticket: SFTPChannel.Ticket
        /// Asks for the rest of a piece the server answered only in part.
        let isRest: Bool
    }

    private static let firstDepth = 4

    private let session: SFTPSession
    private let channel: SFTPChannel
    private var handle: Data?
    /// Where the next byte for the caller is.
    private var position: UInt64 = 0
    /// The bytes that start at `position`: an answer that was taken only in part.
    private var leftover = Data()
    /// The requests under way, in file order; the first starts where `leftover` ends.
    private var requests: [Chunk] = []
    /// Where the request after the last one starts.
    private var nextOffset: UInt64 = 0
    private var sawEnd = false
    private var depth = SFTPFileReader.firstDepth
    /// How many reads followed one another since the file was opened or the position jumped.
    private var readsInARow = 0
    /// How much is asked for with one request: less than the usual block once the server has
    /// shown that it never gives more.
    ///
    /// A single short answer says nothing (the file may end there, the server may have been
    /// interrupted); the same short length three times in a row for requests of the full size is
    /// the server's limit.
    private var block = SFTPSession.blockSize
    private var shortAnswer: Int?
    private var shortAnswers = 0
    private var window = TransferWindow()
    /// Set by `interrupt`; the waits for answers look at it.
    ///
    /// Only this reader's requests are given up, the channel is shared with other transfers and
    /// stays open.
    private let abort = CancellationFlag()

    /// A reader of the file `handle` stands for, opened on `channel` of `session`, at its start.
    internal init(session: SFTPSession, channel: SFTPChannel, handle: Data) {
        self.session = session
        self.channel = channel
        self.handle = handle
    }

    /// Reads up to `count` bytes from the position on; nil at the end of the file.
    ///
    /// What was read before a failure is returned; the failure shows again when the read is repeated.
    internal func read(upToCount count: Int) throws -> Data? {
        if abort.isCancelled { throw NetworkError.cancelled }
        guard let handle, count > 0 else {
            return nil
        }
        let ahead = readAhead()
        var result = Data()
        do {
            try fill(wanted(count, ahead: ahead), handle)
            while result.count < count {
                if !leftover.isEmpty {
                    takeLeftover(into: &result, upTo: count)
                    continue
                }
                // Whenever more is wanted than `leftover` holds, `fill` has put a request under way
                // for it, so a request is there unless the end was seen.
                guard !sawEnd, let chunk = requests.first else { break }
                try receive(chunk, handle)
                // Kept full while the caller still waits for more.
                try fill(wanted(count - result.count, ahead: ahead), handle)
            }
            // The next requests are on their way before the caller has handled this piece.
            if !sawEnd, ahead > 0 { try fill(min(ahead, window.limit(block: block)), handle) }
        } catch {
            // What was read is delivered; the failure shows again when the read is repeated.
            rewind(to: position)
            if result.isEmpty { throw error }
        }
        return result.isEmpty ? nil : result
    }

    /// Moves to `offset`; a short step forward within what was read ahead keeps the rest.
    internal func seek(to offset: UInt64) throws {
        if abort.isCancelled { throw NetworkError.cancelled }
        if offset == position {
            return
        }
        if offset > position, offset - position <= UInt64(leftover.count) {
            leftover = leftover.dropFirst(Int(offset - position))
            position = offset
            return
        }
        rewind(to: offset)
        // A jump: what follows may be one small read, so nothing is read ahead until it reads on.
        depth = Self.firstDepth
        readsInARow = 0
    }

    /// Gives up the requests under way and closes the handle, without waiting for the server.
    internal func close() {
        guard let handle else {
            return
        }
        self.handle = nil
        abandonRequests()
        session.closeHandle(handle, on: channel)
    }

    /// Ends a read that waits for the server, from any thread; the channel stays open.
    internal func interrupt() { abort.cancel() }

    /// How many requests to keep under way beyond what this read needs, and counts the read.
    ///
    /// None for the first read after opening or a jump; the window doubles with every read in a row.
    private func readAhead() -> Int {
        var ahead = 0
        if readsInARow > 0 {
            depth = min(SFTPSession.window, depth * 2)
            ahead = min(depth, window.limit(block: block))
        }
        readsInARow += 1
        return ahead
    }

    /// How many requests should be under way while `missing` bytes are still wanted.
    private func wanted(_ missing: Int, ahead: Int) -> Int {
        let needed = (max(0, missing - leftover.count) + block - 1) / block
        return min(window.limit(block: block), max(ahead, needed))
    }

    /// Moves what `leftover` holds into `result`, no more than `count` bytes in all.
    private func takeLeftover(into result: inout Data, upTo count: Int) {
        let taken = leftover.prefix(count - result.count)
        if result.isEmpty { result.reserveCapacity(min(count, max(taken.count, 1 << 20))) }
        result.append(taken)
        leftover = leftover.dropFirst(taken.count)
        position += UInt64(taken.count)
    }

    /// Waits for the answer to the first request under way, `chunk`, and puts its data in `leftover`.
    ///
    /// The end of the file stops the requests; a short answer asks for the rest of the piece first.
    private func receive(_ chunk: Chunk, _ handle: Data) throws {
        let packet: SFTPPacket
        do {
            packet = try channel.wait(for: chunk.ticket, timeout: session.timeout, cancellation: abort)
        } catch {
            // The answer is not coming, or the channel is gone. The window is dropped
            // with it so that a later read starts clean.
            requests.removeFirst()
            throw error
        }
        requests.removeFirst()
        if packet.statusCode == SFTPError.endOfFile {
            endReached()
            return
        }
        var decoder = try packet.expect(.data)
        let data = try decoder.bytes()
        guard data.count <= chunk.length else { throw NetworkError.unexpected("more data than asked for") }
        if data.isEmpty {
            // An answer without data and without an end of file status: nothing more comes.
            endReached()
            return
        }
        window.moved(data.count)
        leftover = data
        learnLimit(answer: data.count, of: chunk)
        if data.count < chunk.length {
            // A short answer leaves a gap before the requests behind it; the rest of
            // this piece is asked for first.
            let rest = try sendRequest(
                at: chunk.offset + UInt64(data.count),
                length: chunk.length - data.count,
                isRest: true,
                handle
            )
            requests.insert(rest, at: 0)
        }
    }

    /// Notes the length of an answer to a request of the full block, and shrinks the block when the
    /// server has given the same short length three times in a row.
    private func learnLimit(answer length: Int, of chunk: Chunk) {
        guard !chunk.isRest, chunk.length == block else {
            return
        }
        if length == chunk.length {
            (shortAnswer, shortAnswers) = (nil, 0)
        } else if length == shortAnswer {
            shortAnswers += 1
            // Every answer stops at the same length: more is not asked for from now
            // on, which spares a second request for the rest of every piece.
            if shortAnswers >= 3 { block = max(512, length) }
        } else {
            (shortAnswer, shortAnswers) = (length, 1)
        }
    }

    /// The file ends here: nothing more is asked for.
    private func endReached() {
        sawEnd = true
        abandonRequests()
    }

    private func sendRequest(at offset: UInt64, length: Int, isRest: Bool, _ handle: Data) throws -> Chunk {
        let ticket = try channel.send(.read, cancellation: abort) { encoder in
            encoder.bytes(handle)
            encoder.u64(offset)
            encoder.u32(UInt32(length))
        }
        return Chunk(offset: offset, length: length, ticket: ticket, isRest: isRest)
    }

    /// Tops the window up to `want` requests.
    private func fill(_ want: Int, _ handle: Data) throws {
        while requests.count < want, !sawEnd {
            requests.append(try sendRequest(at: nextOffset, length: block, isRest: false, handle))
            nextOffset += UInt64(block)
        }
    }

    private func abandonRequests() {
        for request in requests {
            channel.abandon(request.ticket)
        }
        requests = []
    }

    /// Forgets everything that was read ahead; the next read starts at `offset`.
    private func rewind(to offset: UInt64) {
        abandonRequests()
        leftover = Data()
        position = offset
        nextOffset = offset
        sawEnd = false
    }

    deinit {
        // Dropped without `close`: the handle is closed all the same, which never waits.
        guard let handle else {
            return
        }
        abandonRequests()
        session.closeHandle(handle, on: channel)
    }
}

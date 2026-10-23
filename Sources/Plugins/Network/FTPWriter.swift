import AFMKernel
import Foundation

/// A file being uploaded (`STOR`, or `APPE` to continue one).
///
/// Used by one thread; `interrupt` may be called from another thread to end a write that waits for
/// a server which does not answer.
///
/// Used by one thread at a time, as `FileWriter` allows; `interrupt` touches only the flag and
/// the connection, the latter under `holdLock`.
internal final class FTPWriter: FileWriter, @unchecked Sendable {
    private let session: FTPSession
    private let path: String
    private let asText: Bool
    private var active: (stream: NetStream, connection: FTPConnection)?
    /// The same connection for `interrupt`, which cannot look at `active`.
    private let connection: FTPConnection
    private var converter = LineEndConverter()
    private var failed = false
    private var written: Int64 = 0
    /// The length the file had when this writer started: 0 for a new file.
    ///
    /// What is written follows it, and the length the server reports when the file is closed must
    /// be the sum.
    private let start: Int64
    private let abort = CancellationFlag()
    /// Guards `isHolding`: the connection may be cut by `interrupt` only while this writer has it.
    private let holdLock = NSLock()
    private var isHolding = true

    /// A writer for a transfer that `connection` started: `stream` takes the data of `path`, which had `start`
    /// bytes; `asText` converts line ends.
    internal init(
        session: FTPSession,
        connection: FTPConnection,
        stream: NetStream,
        path: String,
        asText: Bool,
        start: Int64
    ) {
        self.session = session
        self.path = path
        self.asText = asText
        self.connection = connection
        self.start = start
        active = (stream, connection)
    }

    /// Sends the next bytes of the file.
    internal func write(_ data: Data) throws {
        if abort.isCancelled {
            failed = true
            throw NetworkError.cancelled
        }
        guard let active else { throw NetworkError.connectionLost }
        do {
            try active.stream.write(
                asText ? converter.toNetwork(data) : data,
                timeout: session.timeout,
                cancellation: abort
            )
            written += Int64(data.count)
            session.noteProgress()
        } catch {
            failed = true
            throw error
        }
    }

    /// Ends the upload, checks the length the server has, and sets the date and permissions it takes.
    internal func close(attributes: FileAttributes) throws {
        guard let active else {
            return
        }
        self.active = nil
        let interrupted = abort.isCancelled
        do {
            if interrupted { throw NetworkError.cancelled }
            if failed { throw NetworkError.connectionLost }
            try active.stream.finishWriting(timeout: session.timeout, cancellation: abort)
        } catch {
            if interrupted { active.connection.abandonTransfer() } else { active.connection.abortTransfer() }
            giveBack(active.connection)
            if failed, !interrupted {
                return
            }
            throw error
        }
        defer { giveBack(active.connection) }
        try active.connection.finishTransfer(cancellation: abort)
        // The server said the transfer is complete; what it has is compared with what was
        // sent. A continued file may have kept what lay beyond the new end, or have been
        // started anew (`APPE` taken for `STOR`), and an upload that lost its end can still be
        // answered with a 226. In text mode the server's length is not ours.
        if !asText {
            var length: Int64?
            if active.connection.offers("SIZE") { length = try active.connection.size(of: path, cancellation: abort) }
            if length == nil, active.connection.offers("MLST") {
                length = try active.connection.status(of: path, cancellation: abort)
                    .flatMap { entry in entry.isDirectory ? nil : entry.size }
            }
            if let length, length != start + written {
                throw NetworkError.unexpected(
                    "the file on the server has \(length) bytes after the upload, not \(start + written)"
                )
            }
        }
        // On the connection the file came through, which is free again.
        session.applyAfterUpload(attributes, to: path, on: active.connection)
    }

    /// Gives the connection back to the session; `interrupt` no longer cuts it.
    private func giveBack(_ connection: FTPConnection) {
        holdLock.lock()
        isHolding = false
        holdLock.unlock()
        session.release(connection, transfer: .write)
    }

    /// Ends a write that waits, from any thread.
    internal func interrupt() {
        abort.cancel()
        holdLock.lock()
        if isHolding { connection.interrupt() }
        holdLock.unlock()
    }

    deinit {
        // Dropped without `close`: aborting waits for the server, which happens in the background.
        guard let active else {
            return
        }
        let owner = session
        Background.run(lane: owner) {
            active.connection.abortTransfer()
            owner.release(active.connection, transfer: .write)
        }
    }
}

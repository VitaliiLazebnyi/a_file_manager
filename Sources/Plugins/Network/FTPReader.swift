import AFMKernel
import Foundation

/// A file on an FTP server being downloaded (`RETR`).
///
/// The transfer starts with the first read and holds one connection until the end of the file or
/// `close`. Seeking restarts the transfer at the new position with `REST` (spec 11 › Target already
/// exists and resume). Used by one thread at a time; only `close` and `interrupt` may also be
/// called from another thread, to end a read that waits for a server which does not answer. The
/// read then fails, and its thread gives the connection back. After `interrupt` every read and seek
/// fails.
///
/// Used by one thread at a time, as `FileReader` allows; what `close` and `interrupt` touch is
/// guarded by `stateLock` (see there).
internal final class FTPReader: FileReader, @unchecked Sendable {
    /// A short way forward is read and thrown away instead of starting a new transfer.
    private static let skipLimit: UInt64 = 256 * 1_024

    private let session: FTPSession
    private let path: String
    private let asText: Bool
    private var active: (stream: NetStream, connection: FTPConnection)?
    private var position: UInt64 = 0
    private var atEnd = false
    private var converter = LineEndConverter()
    /// Guards `active` (written under it by the owning thread), `isBusy` and `wasClosed`.
    /// `position`, `atEnd` and the converter belong to the owning thread alone; `close` and
    /// `interrupt`, which may come from another thread, do not touch them.
    private let stateLock = NSLock()
    /// True while a read or a seek of the owning thread is under way.
    private var isBusy = false
    private var wasClosed = false
    /// Set by `interrupt`; the waits of this reader (also for a free connection) look at it.
    private let abort = CancellationFlag()

    /// A reader of `path`, which starts no transfer until the first read; `asText` converts line ends.
    internal init(session: FTPSession, path: String, asText: Bool) {
        self.session = session
        self.path = path
        self.asText = asText
    }

    private func setActive(_ value: (stream: NetStream, connection: FTPConnection)?) {
        stateLock.lock()
        active = value
        let interrupted = wasClosed || abort.isCancelled
        // Under the lock, like `interrupt`: once `active` is cleared the connection may be another thread's.
        if interrupted { value?.connection.interrupt() }
        stateLock.unlock()
    }

    /// Marks a call of the owning thread as under way; false after `close`.
    private func begin() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !wasClosed else {
            return false
        }
        isBusy = true
        return true
    }

    /// Marks the call of the owning thread as over; cleans up when `close` came meanwhile.
    private func end() {
        stateLock.lock()
        isBusy = false
        let closed = wasClosed
        stateLock.unlock()
        // Closed from another thread while this call ran: this thread cleans up.
        if closed { stop() }
    }

    /// The next bytes of the file, at most `count`; nil at its end.
    internal func read(upToCount count: Int) throws -> Data? {
        if abort.isCancelled { throw NetworkError.cancelled }
        guard begin() else {
            return nil
        }
        defer { end() }
        while !atEnd {
            let running: (stream: NetStream, connection: FTPConnection)
            if let active {
                running = active
            } else {
                running = try session.beginDownload(path, asText: asText, offset: position, cancellation: abort)
                setActive(running)
            }
            do {
                guard
                    let block = try running.stream.read(upToCount: count, timeout: session.timeout, cancellation: abort)
                else {
                    setActive(nil)
                    atEnd = true
                    defer { session.release(running.connection, transfer: .read) }
                    try running.connection.finishTransfer(cancellation: abort)
                    let rest = converter.finishLocal()
                    return rest.isEmpty ? nil : rest
                }
                session.noteProgress()
                position += UInt64(block.count)
                let data = asText ? converter.toLocal(block) : block
                // A block that was only half a line end gives nothing yet.
                if !data.isEmpty {
                    return data
                }
            } catch {
                stop()
                throw error
            }
        }
        return nil
    }

    /// Moves to `offset`: a short way forward is read and thrown away, else the transfer starts again there.
    internal func seek(to offset: UInt64) throws {
        if abort.isCancelled { throw NetworkError.cancelled }
        // Like a read, a seek is a call `close` must not run beside: it reads from the
        // connection and changes the position.
        guard begin() else { throw NetworkError.cancelled }
        defer { end() }
        if offset == position, !atEnd {
            return
        }
        if asText { throw FileSystemError.notSupported("Continuing a transfer in text mode") }
        if let active, !atEnd, offset > position, offset - position <= Self.skipLimit {
            var left = Int(offset - position)
            do {
                while left > 0 {
                    guard
                        let block = try active.stream.read(
                            upToCount: left,
                            timeout: session.timeout,
                            cancellation: abort
                        )
                    else { break }
                    left -= block.count
                    position += UInt64(block.count)
                }
            } catch {
                stop()
                throw error
            }
            if left == 0 {
                return
            }
        }
        stop()
        position = offset
        atEnd = false
    }

    /// Takes the running transfer out of this reader's hands; nil when there is none.
    private func detach() -> (stream: NetStream, connection: FTPConnection)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let running = active
        active = nil
        return running
    }

    /// Ends the running transfer before its end and gives the connection back.
    ///
    /// Called by the owning thread; waits for the server's answer to the broken transfer.
    private func stop() {
        guard let running = detach() else {
            return
        }
        // A server that is not answering is not asked how the transfer ended.
        running.connection.stopTransfer(cancellation: abort)
        session.release(running.connection, transfer: .read)
    }

    /// Ends a read that waits, from any thread; every read and seek fails after it.
    internal func interrupt() {
        abort.cancel()
        // Under the lock: a connection that was given back is somebody else's.
        stateLock.lock()
        active?.connection.interrupt()
        stateLock.unlock()
    }

    /// Returns at once, from any thread.
    ///
    /// A call under way on the owning thread is cut short and that thread cleans up; otherwise the
    /// server is told in the background that the transfer is over, which may take as long as the
    /// server takes to answer.
    internal func close() {
        stateLock.lock()
        wasClosed = true
        if isBusy {
            // A read is under way on another thread, perhaps waiting for data that never
            // comes: cutting the connection ends it. Decided and done under the lock, as in
            // `interrupt`: the reading thread clears `active` under it before it gives the
            // connection back, so what is cut here is still this reader's.
            active?.connection.interrupt()
            stateLock.unlock()
            return
        }
        let running = active
        active = nil
        stateLock.unlock()
        guard let running else {
            return
        }
        let (owner, gaveUp) = (session, abort.isCancelled)
        owner.noteReturning(1)
        Background.run(lane: owner) {
            if gaveUp { running.connection.abandonTransfer() } else { running.connection.abortTransfer() }
            owner.release(running.connection, transfer: .read)
            owner.noteReturning(-1)
        }
    }

    deinit {
        // Dropped without `close`: the server is told in the background, not on this thread.
        guard let active else {
            return
        }
        let owner = session
        Background.run(lane: owner) {
            active.connection.abortTransfer()
            owner.release(active.connection, transfer: .read)
        }
    }
}

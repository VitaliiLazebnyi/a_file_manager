import AFMKernel
import Foundation

/// Sending, in pieces that each have their own time limit.
extension NetStream {
    /// Uploads go out in pieces of this size, a few at a time.
    private static let sendPiece = 128 * 1_024
    /// How many pieces are under way at the same time.
    private static let sendsInFlight = 4

    /// Sends `data` in pieces.
    ///
    /// Every piece has its own time-out, so a big block over a slow uplink goes through as long as
    /// it keeps moving, and a few pieces are under way at a time to keep the line busy.
    internal func write(_ data: Data, timeout: TimeInterval, cancellation: CancellationFlag?) throws {
        if data.count <= Self.sendPiece {
            try send(data, isFinal: false, timeout: timeout, cancellation: cancellation)
            return
        }
        var outstanding: [Pending<Bool>] = []
        var offset = data.startIndex
        do {
            while offset < data.endIndex {
                let end = min(offset + Self.sendPiece, data.endIndex)
                outstanding.append(submit(data[offset..<end], isFinal: false))
                offset = end
                if outstanding.count >= Self.sendsInFlight {
                    try complete(outstanding.removeFirst(), timeout: timeout, cancellation: cancellation)
                }
            }
            for pending in outstanding { try complete(pending, timeout: timeout, cancellation: cancellation) }
        } catch {
            // What was not sent in time will not be sent later, behind the caller's back.
            close()
            throw error
        }
    }

    /// Sends one piece, or the end of the data when `isFinal`, and waits until it is out.
    ///
    /// A piece that does not go out in time closes the stream.
    internal func send(_ data: Data?, isFinal: Bool, timeout: TimeInterval, cancellation: CancellationFlag?) throws {
        do {
            try complete(submit(data, isFinal: isFinal), timeout: timeout, cancellation: cancellation)
        } catch {
            // What was not sent in time will not be sent later, behind the caller's back.
            close()
            throw error
        }
    }

    private func complete(_ sent: Pending<Bool>, timeout: TimeInterval, cancellation: CancellationFlag?) throws {
        guard let succeeded = try sent.wait(timeout: timeout, cancellation: cancellation) else {
            throw NetworkError.timedOut("sending")
        }
        if !succeeded { throw NetworkError.connectionLost }
    }
}

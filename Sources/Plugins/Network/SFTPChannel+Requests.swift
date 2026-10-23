import AFMKernel
import Foundation

/// Requests as tickets: one is sent, its answer is waited for or given up.
extension SFTPChannel {
    /// A request that was sent, to be waited for or given up.
    internal struct Ticket {
        /// The request number the answer will carry.
        internal let id: UInt32
        /// Where the reading thread delivers the answer.
        internal let answer: Pending<SFTPPacket>
    }

    /// The answer when it has arrived; never waits.
    internal func poll(_ ticket: Ticket) -> SFTPPacket? { ticket.answer.poll() }

    /// Sends a request and waits for its answer, which may be an error status.
    internal func request(
        _ type: SFTPRequest,
        timeout: TimeInterval,
        cancellation: CancellationFlag?,
        _ build: (inout SFTPEncoder) -> Void
    ) throws -> SFTPPacket {
        let ticket = try send(type, cancellation: cancellation, build)
        do {
            return try wait(for: ticket, timeout: timeout, cancellation: cancellation)
        } catch {
            abandon(ticket)
            throw error
        }
    }
}

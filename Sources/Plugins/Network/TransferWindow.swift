import Foundation

/// How many requests of one transfer are kept under way.
///
/// More requests make a fast line with a long delay fast; on a slow line they only stand in the
/// way, because everything else on the shared channel (a listing, another file) is answered after
/// them. The window therefore follows what the line carries: about `seconds` worth of data,
/// measured over the transfer so far, between `least` and `SFTPSession.window` requests.
internal struct TransferWindow {
    private static let seconds = 1.5
    private static let least = 2

    private let started = Date()
    private var bytes = 0

    /// Counts bytes the server has confirmed.
    internal mutating func moved(_ count: Int) { bytes += count }

    /// The most requests to keep under way now, for requests of `block` bytes.
    internal func limit(block: Int) -> Int {
        let elapsed = Date().timeIntervalSince(started)
        // Nothing is known in the first moments; the caller's own slow start applies.
        guard elapsed > 0.25, bytes > 0 else {
            return SFTPSession.window
        }
        let wanted = Double(bytes) / elapsed * Self.seconds / Double(max(1, block))
        return max(Self.least, min(SFTPSession.window, Int(wanted.rounded(.up))))
    }
}

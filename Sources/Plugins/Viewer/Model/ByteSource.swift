import AFMKernel
import Foundation

/// Random access to the bytes of what is being viewed.
///
/// The viewer never holds a file whole: it asks for the pieces it shows (spec 10 › Window model:
/// the text modes stream the file). `read` blocks and is safe to call from several threads at once;
/// never call it on the main thread.
internal protocol ByteSource: AnyObject, Sendable {
    /// The number of bytes, fixed when the source was made.
    var length: Int64 { get }
    /// The bytes from `offset` on, at most `count`; fewer only at the end of the file.
    func read(at offset: Int64, count: Int) throws -> Data
    /// `read(at:count:)`, ended early, by throwing, once `cancellation` is set: a read that is
    /// blocked in a server's answer is interrupted, so whoever drops the work does not wait
    /// for it.
    func read(at offset: Int64, count: Int, cancellation: CancellationFlag) throws -> Data
    /// Lets go of whatever the source holds open. Reading afterwards opens it again.
    func close()
}

/// What every source can do with the reads it has.
extension ByteSource {
    /// Nothing to let go of: the source holds nothing open.
    internal func close() {
        // A source that holds something open has a `close` of its own.
    }

    /// `read(at:count:)` after a look at the flag: a source that cannot be interrupted ends only
    /// before it starts.
    internal func read(at offset: Int64, count: Int, cancellation: CancellationFlag) throws -> Data {
        try cancellation.throwIfCancelled()
        return try read(at: offset, count: count)
    }

    /// `read(at:count:)`, interruptible when there is a flag.
    internal func read(at offset: Int64, count: Int, interruptedBy cancellation: CancellationFlag?) throws -> Data {
        guard let cancellation else {
            return try read(at: offset, count: count)
        }
        return try read(at: offset, count: count, cancellation: cancellation)
    }

    /// The bytes of `range`, clipped to the file.
    internal func read(_ range: Range<Int64>) throws -> Data {
        try read(range, cancellation: nil)
    }

    /// The bytes of `range`, clipped to the file; interruptible when there is a flag.
    internal func read(_ range: Range<Int64>, cancellation: CancellationFlag?) throws -> Data {
        let lower = max(0, min(range.lowerBound, length))
        let upper = max(lower, min(range.upperBound, length))
        guard upper > lower else {
            return Data()
        }
        return try read(at: lower, count: Int(upper - lower), interruptedBy: cancellation)
    }
}

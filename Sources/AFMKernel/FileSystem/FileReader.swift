public import Foundation

/// Access to the contents of a file.
///
/// Used by one thread at a time; only `interrupt` may be called from another thread meanwhile.
public protocol FileReader: AnyObject, Sendable {
    /// The next block, or nil at the end of the file.
    func read(upToCount count: Int) throws -> Data?
    /// Continues reading at a position counted from the start of the file.
    func seek(to offset: UInt64) throws
    /// Lets go of the file; nothing is read afterwards. On the reader's own thread.
    func close()
    /// Ends a `read` or `seek` that is waiting (for a server that does not answer, for a long
    /// way through a compressed stream): it throws soon, and so does every later one. **May be
    /// called from any thread**, at any time, more than once; it returns at once and never
    /// waits for the other thread. The reader's owner still calls `close` afterwards, on its
    /// own thread. The default does nothing: a reader that never waits long needs no more.
    func interrupt()
}

/// What a reader does not have to offer.
extension FileReader {
    /// Does nothing: a reader that never waits long has nothing to end.
    public func interrupt() {
        // Nothing waits.
    }
}

public import Foundation

/// Writes the contents of a new file, block after block.
///
/// Used by one thread at a time; only `interrupt` may be called from another thread meanwhile.
public protocol FileWriter: AnyObject, Sendable {
    /// Adds `data` at the end of what was written so far.
    func write(_ data: Data) throws
    /// Finishes the file and gives it the attributes the file system can keep.
    func close(attributes: FileAttributes) throws
    /// Ends a `write` or `close(attributes:)` that is waiting: it throws soon, and so does
    /// every later `write`. **May be called from any thread**, at any time, more than once; it
    /// returns at once. The owner still calls `close(attributes:)` afterwards (which may then
    /// throw as well) and removes what arrived, as after any failed write. The default does
    /// nothing.
    func interrupt()
}

/// What a writer does not have to offer.
extension FileWriter {
    /// Does nothing: a writer that never waits long has nothing to end.
    public func interrupt() {
        // Nothing waits.
    }
}

/// Ties a flag to the reader or writer of a transfer, so that a Cancel ends a read or write
/// that waits.
extension CancellationFlag {
    /// Interrupts `reader` when the flag is set, until the returned object is released: what a transfer does for the
    /// time it reads.
    ///
    /// The reader is not kept alive by it.
    public func interrupting(_ reader: any FileReader) -> AnyObject {
        onCancel { [weak reader] in reader?.interrupt() }
    }

    /// Interrupts `writer` when the flag is set, until the returned object is released: what a transfer does for the
    /// time it writes.
    ///
    /// The writer is not kept alive by it.
    public func interrupting(_ writer: any FileWriter) -> AnyObject {
        onCancel { [weak writer] in writer?.interrupt() }
    }
}

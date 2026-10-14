import Foundation

extension CancellationFlag {
    /// Interrupts `reader` when the flag is set, until the returned object is released: what
    /// a transfer does for the time it reads. The reader is not kept alive by it.
    public func interrupting(_ reader: any FileReader) -> AnyObject {
        onCancel { [weak reader] in reader?.interrupt() }
    }

    public func interrupting(_ writer: any FileWriter) -> AnyObject {
        onCancel { [weak writer] in writer?.interrupt() }
    }
}

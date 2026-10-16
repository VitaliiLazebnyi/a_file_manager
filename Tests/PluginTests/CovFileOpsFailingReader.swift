import AFMKernel
import Foundation

/// A reader that hands over `allowed` blocks of the reader below and then fails, as a disk that stops halfway does.
///
/// Unchecked: used by one thread at a time, as `FileReader` allows; `interrupt` is handed to the reader below,
/// which is safe from any thread.
internal final class CovFileOpsFailingReader: FileReader, @unchecked Sendable {
    private let base: any FileReader
    private var allowed: Int

    /// Reads through `base` for `allowed` blocks.
    internal init(_ base: any FileReader, allowed: Int) {
        self.base = base
        self.allowed = allowed
    }

    /// The next block, or the failure once the allowed ones are read.
    internal func read(upToCount count: Int) throws -> Data? {
        guard allowed > 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        allowed -= 1
        return try base.read(upToCount: count)
    }

    /// Moves the reader below.
    internal func seek(to offset: UInt64) throws {
        try base.seek(to: offset)
    }

    /// Interrupts the reader below.
    internal func interrupt() {
        base.interrupt()
    }

    /// Closes the reader below.
    internal func close() {
        base.close()
    }

    deinit {
        // The reader below is closed by whoever opened it.
    }
}

import AFMKernel
import Foundation
import TestSupport

/// A reader that hands over blocks of the reader below while the budget of its path lasts, and then fails, as a
/// disk that stops halfway does. Every reader of the path draws on the one budget.
///
/// Unchecked: used by one thread at a time, as `FileReader` allows; `interrupt` is handed to the reader below,
/// which is safe from any thread, and the budget is a `Shared` box.
internal final class CovFileOpsFailingReader: FileReader, @unchecked Sendable {
    private let base: any FileReader
    private let path: String
    private let budget: Shared<[String: Int]>

    /// Reads through `base` while `budget` has reads left for `path`.
    internal init(_ base: any FileReader, path: String, budget: Shared<[String: Int]>) {
        self.base = base
        self.path = path
        self.budget = budget
    }

    /// The next block, or the failure once the budget is spent.
    internal func read(upToCount count: Int) throws -> Data? {
        var allowed = false
        budget.modify { reads in
            let left = reads[path, default: 0]
            allowed = left > 0
            reads[path] = max(0, left - 1)
        }
        guard allowed else {
            throw CocoaError(.fileReadUnknown)
        }
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

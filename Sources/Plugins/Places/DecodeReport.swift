import Foundation

/// Counts what a lenient decode had to leave out, so whoever loads can tell the user.
///
/// Made for one decode and used only by the thread that runs it: the decode runs synchronously inside
/// `DecodeReport.$current.withValue(report) { ... }`, which binds the report for that thread alone.
internal final class DecodeReport: @unchecked Sendable {
    /// The report of the decode running on this thread; nil outside `$current.withValue`.
    @TaskLocal internal static var current: DecodeReport?

    /// How many stored elements were left out so far.
    internal var skipped = 0

    deinit {
        // Nothing to release.
    }
}

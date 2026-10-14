import Foundation

/// Runs long work in the background with a progress window. Jobs run one after another in the
/// order they were handed in; while any is running or waiting, `isBusy` is true and commands
/// that change files or panels do not start.
@MainActor
public protocol JobService: AnyObject {
    var isBusy: Bool { get }
    /// `work` runs on a background thread; `completion` on the main thread with its result,
    /// also when the job was cancelled (the work then returns early with what it has).
    func run<Result: Sendable>(
        title: String,
        work: @escaping @Sendable (any JobMonitor) -> Result,
        completion: @escaping @MainActor (Result) -> Void
    )
}

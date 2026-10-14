/// The link between running work and the outside.
///
/// Used from the work's own thread.
public protocol JobMonitor: AnyObject, Sendable {
    /// Set when the user presses Cancel or the program quits; the work checks it regularly.
    var cancellation: CancellationFlag { get }
    /// Says how far the work is. May block for as long as the user keeps the job paused. Do
    /// not call it while holding a lock that the main thread, or a question asked through
    /// `ask`, may take.
    func report(_ progress: JobProgress)
    /// Asks the user something in the middle of the work and waits for the answer.
    func ask<Answer: Sendable>(_ question: @MainActor @Sendable () -> Answer) -> Answer
}

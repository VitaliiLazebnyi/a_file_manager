import Foundation

/// How far a long operation is (spec 07 › Progress window).
public struct JobProgress: Sendable {
    /// What is being worked on, ready to show: for a copy, `From: …` and `To: …`.
    public var lines: [String]
    /// Files plus folders.
    public var itemsDone: Int
    public var itemsTotal: Int
    public var bytesDone: Int64
    public var bytesTotal: Int64

    public init(lines: [String], itemsDone: Int, itemsTotal: Int, bytesDone: Int64 = 0, bytesTotal: Int64 = 0) {
        self.lines = lines
        self.itemsDone = itemsDone
        self.itemsTotal = itemsTotal
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
    }

    /// What speed and remaining time are measured in: bytes when the job moves data, else items.
    public var measuresBytes: Bool { bytesTotal > 0 }
    public var amountDone: Int64 { measuresBytes ? bytesDone : Int64(itemsDone) }
    public var amountTotal: Int64 { measuresBytes ? bytesTotal : Int64(itemsTotal) }

    /// Overall progress 0…1.
    public var fraction: Double {
        amountTotal > 0 ? min(1, Double(amountDone) / Double(amountTotal)) : 0
    }
}

/// The link between running work and the outside. Used from the work's own thread.
public protocol JobMonitor: AnyObject, Sendable {
    /// Set when the user presses Cancel or the program quits; the work checks it regularly.
    var cancellation: CancellationFlag { get }
    /// Says how far the work is. May block for as long as the user keeps the job paused. Do
    /// not call it while holding a lock that the main thread, or a question asked through
    /// `ask`, may take.
    func report(_ progress: JobProgress)
    /// Asks the user something in the middle of the work and waits for the answer.
    func ask<Answer: Sendable>(_ question: sending @MainActor () -> Answer) -> Answer
}

/// A job that was handed to the job service.
@MainActor
public protocol JobHandle: AnyObject {
    var title: String { get }
    var isFinished: Bool { get }
    /// Stops the job, or takes it out of the queue if it has not started.
    func cancel()
}

/// Runs long work in the background with a progress window. Jobs run one after another in the
/// order they were handed in; while any is running or waiting, `isBusy` is true and commands
/// that change files or panels do not start.
@MainActor
public protocol JobService: AnyObject {
    var isBusy: Bool { get }
    /// `work` runs on a background thread; `completion` on the main thread with its result,
    /// also when the job was cancelled (the work then returns early with what it has).
    @discardableResult
    func run<Result: Sendable>(
        title: String, work: @escaping @Sendable (any JobMonitor) -> Result,
        completion: @escaping @MainActor (Result) -> Void
    ) -> any JobHandle
    /// Cancels every job; `completion` runs on the main thread once none is left.
    func cancelAll(then completion: @escaping () -> Void)
}

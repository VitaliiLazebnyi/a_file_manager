import AFMKernel

@testable import FileOperationsPlugin

/// How one job went.
internal struct Outcome: Sendable {
    /// What the job returned.
    internal var result = JobResult()
    /// Seconds from the start to the completion.
    internal var wall = 0.0
    /// How many progress reports came.
    internal var reports = 0
    /// The errors the job asked about.
    internal var errors: [String] = []
    /// How often the job was paused.
    internal var pauses = 0
    /// Whether the cancel was sent.
    internal var cancelSent = false
    /// The progress reported last.
    internal var last: JobProgress?
}

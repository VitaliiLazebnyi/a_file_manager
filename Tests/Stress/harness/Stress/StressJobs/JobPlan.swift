import FileOperationsPlugin

/// How to run one job: its name, the controller's seed, the interference and the time allowed.
internal struct JobPlan: Sendable {
    /// The job's title and the run's name in the findings.
    internal let label: String
    /// Seeds the controller's random choices.
    internal let seed: UInt64
    /// What the controller does to the job.
    internal let interference: Interference
    /// Seconds before the hang guard ends the process.
    internal let limit: Double
    /// Called with the job before it runs, its delegate already set.
    internal let configure: (@Sendable (FileJob) -> Void)?
}

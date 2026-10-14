/// What happens to a job while it runs.
internal struct Interference: Sendable {
    /// Cancel after this many seconds; nil: never.
    internal var cancelAfter: Double?
    /// Pause and resume at random.
    internal var pauses = false
    /// Cancel from the controller's own thread (the job's cancellation flag) instead of through the
    /// main thread.
    internal var cancelsOffMain = false
}

/// What the window's cancel torture measured.
internal struct CancelStats {
    /// From each cancel to the search's end, in seconds.
    internal var latencies: [Double] = []
    /// The longest of them.
    internal var worstLatency = 0.0
    /// Which search that was, and when it was cancelled.
    internal var worstLabel = ""
    /// The thread count right after each round.
    internal var threadsAfter: [Int] = []
    /// The searches that ended before their cancel came.
    internal var completedInstead = 0
}

internal import AFMKernel

/// What one run of the engine found, and how long it took.
internal struct EngineResult: Sendable {
    /// The results, in the order they came.
    internal let items: [FileItem]
    /// From the start to the end of the run.
    internal let seconds: Double
    /// From the start to the first result; -1 without results.
    internal let first: Double
}

/// One piece of work whose time and memory are measured.
///
/// `prepare` makes what the work needs (a list, a folder, an archive), which is not measured,
/// and returns the work itself, which is.
internal struct Benchmark {
    /// The name the limits are recorded under.
    internal let name: String
    /// What is measured, in a few words.
    internal let summary: String
    /// Makes what the work needs and returns the work.
    internal let prepare: @MainActor () throws -> @MainActor () throws -> Void
}

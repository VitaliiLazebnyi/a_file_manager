/// One timed relayout of the whole file.
internal struct Relayout {
    /// What the layout was.
    internal let label: String
    /// How long it took to index.
    internal let seconds: Double
    /// How many segments of the layout before it reused.
    internal let reused: Int
}

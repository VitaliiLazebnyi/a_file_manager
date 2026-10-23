/// The rows chosen for printing.
internal struct PrintableText {
    /// The rows, as the layout of the document shows them.
    internal var lines: [String]
    /// Whether rows were left out because there were more than the most that are printed.
    internal var truncated: Bool
    /// The rows, each ended by a line end.
    internal var text: String { lines.map { $0 + "\n" }.joined() }
}

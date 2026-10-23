/// One line of the Properties dialog.
internal struct PropertyRow: Equatable {
    /// What the line is about, such as "Size".
    internal let label: String
    /// The fact itself, written out.
    internal let value: String

    /// A line that shows `value` under `label`.
    internal init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

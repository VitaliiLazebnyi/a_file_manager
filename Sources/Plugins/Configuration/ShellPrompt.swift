/// What the user is shown when the parameters begin with `?` (`ShellLine.prompt`).
internal struct ShellPrompt: Equatable {
    /// The line with harmless values written out and every other value as a reference.
    internal var text: String
    /// The values the references in `text` stand for, in order.
    internal var values: [String]
    /// One line per reference saying what it stands for (at most twelve, then how many more).
    internal var legend: String
}

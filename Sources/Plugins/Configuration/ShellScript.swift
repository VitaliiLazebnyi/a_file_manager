/// A command line with its data apart: the text a shell is given, in which every value is a
/// reference to a variable, and the values themselves.
internal struct ShellScript: Equatable {
    /// The line with a reference in place of every value.
    internal var line: String
    /// The values, in the order of their references.
    internal var values: [String]

    /// What the shell runs: the values, handed over as arguments of the shell, are first given
    /// names of their own (so `set --`, `shift` and functions cannot move them), then the line.
    internal var text: String {
        guard !values.isEmpty else {
            return line
        }
        let names = values.indices.map { "\(ShellLine.variable($0))=\"${\($0 + 1)}\"" }.joined(separator: " ")
        return names + "\n" + line
    }

    /// The arguments for a shell after its options: the script for `-c`, a name, and the values.
    internal var arguments: [String] { [text, "afm"] + values }
}

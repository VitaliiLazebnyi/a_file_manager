/// What a shell made of a line, and what the line left behind.
internal struct ShellOutcome {
    /// The bytes of each argument, per case.
    internal var cases: [[[UInt8]]]
    /// Files that appeared in the folder the line ran in.
    internal var created: [String]
}

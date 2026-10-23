/// A Parameters field with its placeholders replaced, and what the expansion found out on the way.
internal struct ExpandedParameters: Equatable {
    /// The line: what the user wrote, with the values of the placeholders apart from it.
    internal var pieces: [ExpandedPiece] = []
    /// The parameters began with `?`: the user is shown the text and may change it.
    internal var asksFirst = false
    /// The list file a list code asked for, to be written before the command starts.
    internal var listFile: ListFile?
    /// An `%A` code used the arguments, so they are not appended a second time.
    internal var usedArguments = false
    /// A code for the name under the cursor met a panel with no such name (`[..]`, an empty
    /// list).
    ///
    /// The text then names the folder instead of a file (`rm -rf %P%N`), so the command must not
    /// run.
    internal var missingName = false
    /// Another reason why the command must not run (a name that cannot stand in a list file).
    internal var problem: String?

    /// The parameters as one readable line: the values written into it, quoted where they
    /// need it.
    ///
    /// For commands of the program, for `cd` and for showing; a shell is given `ShellLine.script`
    /// instead.
    internal var text: String { ShellLine.display(pieces) }
}

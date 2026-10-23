/// One piece of an expanded text.
///
/// Only `text` is ever read as shell text or searched for placeholders; a `value` is data (a file
/// name, a path, the content of a variable) and reaches a program as it is, whatever characters it
/// holds.
internal enum ExpandedPiece: Equatable {
    /// Data the user asked to have pasted into the line as it is (`%Q`, quoting off).
    case raw(String)
    /// What the user wrote.
    case text(String)
    /// Data. The shell gets it in a variable, never as part of the line.
    case value(String)
}

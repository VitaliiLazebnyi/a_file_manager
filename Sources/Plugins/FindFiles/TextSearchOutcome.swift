/// How the search of one file for a text ended.
internal enum TextSearchOutcome {
    /// The text is in the file.
    case found
    /// The file was read to its end and the text is not in it.
    case missing
    /// The search was cancelled, the file could not be read to its end, or a regular expression took too
    /// long: nothing can be said.
    case undecided
}

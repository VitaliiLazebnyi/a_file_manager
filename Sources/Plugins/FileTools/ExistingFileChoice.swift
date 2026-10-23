/// What to do about a file that is in the way of one a tool wants to write.
internal enum ExistingFileChoice {
    /// The new file gets a free name next to it: `name(2).ext`.
    case autoRename
    /// The run stops.
    case cancel
    /// The new file replaces it.
    case overwrite
    /// The new file replaces it, and so does every later one of the run without asking.
    case overwriteAll
    /// The new file is not written.
    case skip
}

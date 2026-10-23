/// Answers to "the file exists" while unpacking.
internal enum UnpackConflictChoice {
    /// Ends the whole Unpack.
    case cancel
    /// Replaces this file.
    case overwrite
    /// Replaces this file and every other one that exists, without asking again.
    case overwriteAll
    /// Leaves this file as it is and does not unpack the member.
    case skip
    /// Leaves this file and every other one that exists, without asking again.
    case skipAll
}

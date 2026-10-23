/// Answers to "the folder already exists at the target".
public enum MergeChoice: Sendable {
    /// The job ends here.
    case cancel
    /// The folder is copied into the one that is there; files of the same names are asked about one by one.
    case merge
    /// The same for this folder and every later one.
    case mergeAll
    /// The folder is not copied.
    case skip
}

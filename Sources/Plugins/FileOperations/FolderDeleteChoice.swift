/// Answers to "The directory … is not empty!" (07 › Delete › Questions).
public enum FolderDeleteChoice: Sendable {
    /// This folder and every later one that is not empty are deleted without a question.
    case all
    /// The job ends here.
    case cancel
    /// The folder is deleted with everything in it.
    case delete
    /// The folder stays.
    case skip
}

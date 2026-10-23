/// Answers to the question about a protected item (`ProtectionQuestion`) or another volume.
///
/// `all` answers the same question for the rest of the job.
public enum ProtectionChoice: Sendable {
    /// Yes, for this item and every later one the same question is about.
    case all
    /// The job ends here.
    case cancel
    /// Yes, for this item.
    case proceed
    /// The item stays as it is.
    case skip
}

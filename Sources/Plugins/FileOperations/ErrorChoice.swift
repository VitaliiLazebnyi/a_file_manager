/// Answers to an error of one step of a job (07 › Errors).
public enum ErrorChoice: Sendable {
    /// The job ends here.
    case abort
    /// The step is tried again.
    case retry
    /// The step is left out and the job goes on.
    case skip
    /// This and every later error is left out without a question.
    case skipAll
}

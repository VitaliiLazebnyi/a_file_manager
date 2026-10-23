import Foundation

/// What a Pack did: the archives it wrote and how it ended.
internal struct PackResult {
    /// The archives that were written.
    internal var archives: [URL] = []
    /// What ended the pack early; nil when it went through or was cancelled.
    internal var failure: (any Error)?
    /// True when the user cancelled the job before it was done.
    internal var cancelled = false
    /// The operands that were packed completely.
    internal var completed: [URL] = []
}

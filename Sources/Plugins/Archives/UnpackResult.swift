import Foundation

/// What an Unpack did: what arrived, what went wrong, whether it was cancelled.
internal struct UnpackResult {
    /// The number of files and folders that were written.
    internal var unpacked = 0
    /// One line for each member or archive that failed, with the reason.
    internal var problems: [String] = []
    /// True when the user cancelled the job before it was done.
    internal var cancelled = false
    /// The first thing that arrived, for the cursor.
    internal var firstTarget: URL?
}

public import Foundation

public struct JobResult: Sendable {
    /// Top-level sources that were processed completely; the panel deselects these.
    public var completed: [URL] = []
    public var cancelled = false
    /// Target location of the last top-level item that was copied or moved.
    public var lastTarget: URL?
    /// Why the job did not start at all, as a message for the user.
    public var refusal: String?
    /// How many steps failed, whatever was answered to the error; and the first few messages.
    public var failureCount = 0
    public var failures: [String] = []
}

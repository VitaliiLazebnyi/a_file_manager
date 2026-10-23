public import Foundation

/// How a job ended: what it finished, where the last item went, and what failed.
public struct JobResult: Sendable {
    /// Top-level sources that were processed completely; the panel deselects these.
    public var completed: [URL] = []
    /// Whether the job was cancelled or aborted before its end.
    public var cancelled = false
    /// Target location of the last top-level item that was copied or moved.
    public var lastTarget: URL?
    /// Why the job did not start at all, as a message for the user.
    public var refusal: String?
    /// How many steps failed, whatever was answered to the error; and the first few messages.
    public var failureCount = 0
    /// The first few failures (up to 20), each as "path: message".
    public var failures: [String] = []
}

/// How far a comparison is (spec 09 › Status line).
public struct SyncProgress: Equatable, Sendable {
    /// The folders listed on the left so far.
    public var leftDirectories = 0
    /// The folders listed on the right so far.
    public var rightDirectories = 0
    /// The pairs read and compared by content so far.
    public var filesCompared = 0
    /// The pairs to be read and compared by content.
    public var filesToCompare = 0
    /// The bytes of the pairs compared by content so far, counted on one side.
    public var bytesCompared: Int64 = 0
    /// The bytes of the pairs to be compared by content, counted on one side.
    public var bytesToCompare: Int64 = 0
}

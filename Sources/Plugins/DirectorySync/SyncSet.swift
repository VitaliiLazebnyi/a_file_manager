/// Directories and options under a name (spec 09 › Saved sync sets).
public struct SyncSet: Codable, Equatable, Sendable {
    /// The name the user saved it under.
    public var name: String
    /// The left directory as the user sees and types it.
    public var left: String
    /// The right directory as the user sees and types it.
    public var right: String
    /// The compare options.
    public var options: SyncOptions
    /// The Show buttons.
    public var show: SyncShow
}
